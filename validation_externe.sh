#!/usr/bin/env bash
# =============================================================================
# KAIROS — VÉRIFICATION GUIDÉE
#
# Cet outil MESURE. Il n'interprète pas.
# Il exécute les mêmes vérifications sur toutes les plateformes, compare les
# empreintes obtenues aux empreintes publiées, et consigne le résultat.
# Un écart n'est pas traité comme une erreur : c'est un résultat, il est
# enregistré tel quel et l'exécution se poursuit.
# Seule une impossibilité technique interrompt l'exécution.
#
# Il n'installe rien hors du répertoire de travail, ne demande aucun droit
# administrateur et ne modifie aucun fichier système.
#
# Plateformes : Linux x86_64 · macOS x86_64 · macOS arm64
# Usage       : bash validation_externe.sh
# Effacer     : rm -rf ~/kairos_verification
#
# Licence Apache 2.0 — Aether Paris SAS / Kairos Systems
# =============================================================================
set -u

WORK="$HOME/kairos_verification"
REPO="https://github.com/KAIROSSYSTEMSCH/KAIROS-VERIFIER.git"
CSV_URL="https://deepchemdata.s3.us-west-1.amazonaws.com/datasets/BBBP.csv"

SCRIPT_ATTENDU="f23de8df0d216dc6d79d0402103dcb2bb5ed1132eee83f10bf698c2cbae6d75c"
CSV_ATTENDU="d07a38487aeac5cee5508413e468043ef3097451d2a112701c2d60be9ec6b662"
PARQUET_ATTENDU="4621ac8d5d4a728a169fb4d5b8c35682b954928a019d575e3eca140cd563489f"

LADDER_ATTENDU="L0 1d9e01d16d638900
L1 84af2aaa28305585
L1b 9984517da6ef41ff
L2 86ca842440c89f74
L3 60da9d0bfeb7bb99
L3b db791086e49a76e2
L4 0bf4f040e2ee2721
L4b 9d40cfbddb0c14ca
L5 687b5cae54c0f69f
L5b d36851807abf6013"

ATT="$WORK/ATTESTATION_DATA.txt"
CONFORMES=0
ECARTS=0

# ---------- portabilité ----------
sha256() { # $1 fichier
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
processeur() {
  if [ -r /proc/cpuinfo ]; then
    grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//'
  else
    sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "non déterminé"
  fi
}
avx512() {
  if [ -r /proc/cpuinfo ]; then
    grep -qw avx512f /proc/cpuinfo && echo oui || echo non
  else
    v="$(sysctl -n hw.optional.avx512f 2>/dev/null || echo 0)"
    [ "$v" = "1" ] && echo oui || echo non
  fi
}
pyver_ok() { # 0 si python3 est dans l'enveloppe mesuree 3.10 a 3.12
  python3 -c 'import sys; v=sys.version_info[:2]; sys.exit(0 if (3,10) <= v <= (3,12) else 1)' 2>/dev/null
}
get_micromamba() {
  [ -x "$WORK/bin/micromamba" ] && return 0
  mkdir -p "$WORK" && cd "$WORK" || return 1
  curl -Ls "https://micro.mamba.pm/api/micromamba/${MAMBA_PLAT}/latest" | tar -xj bin/micromamba >/dev/null 2>&1
}

# ---------- présentation ----------
sep()   { printf '%s\n' "------------------------------------------------------------------"; }
titre() { echo; sep; printf '  %s\n' "$1"; sep; }
etape() { printf '\n· %s\n' "$1"; }
cmd()   { printf '  $ %s\n' "$1"; }
note()  { printf '  %s\n' "$1"; }

compare() { # $1 libellé  $2 attendu  $3 obtenu
  printf '  attendu : %s\n  obtenu  : %s\n' "$2" "$3"
  if [ "$2" = "$3" ]; then
    printf '  >>> IDENTIQUE — %s\n' "$1"
    echo "$1 : IDENTIQUE" >> "$ATT"
    CONFORMES=$((CONFORMES+1))
  else
    printf '  >>> DIFFÉRENT — %s\n' "$1"
    echo "$1 : DIFFERENT (publie $2 / obtenu $3)" >> "$ATT"
    ECARTS=$((ECARTS+1))
  fi
}

abandon() { # impossibilité technique : rien n'est mesurable
  titre "EXÉCUTION INTERROMPUE"
  note "$1"
  note ""
  note "Aucune mesure n'a pu être effectuée à cette étape."
  note "Il ne s'agit pas d'un résultat de vérification."
  note ""
  [ -f "$ATT" ] && { echo "INTERRUPTION TECHNIQUE : $1" >> "$ATT"; note "Journal partiel : $ATT"; }
  note "Contact : security@kairossystems.ch"
  exit 1
}

# ---------- préambule ----------
clear 2>/dev/null || true
titre "KAIROS — VÉRIFICATION GUIDÉE"
note "Cet outil vérifie, sur VOTRE machine, les empreintes publiées par"
note "Kairos Systems. Deux parties :"
note ""
note "  Partie 1 — le calcul numérique produit-il des résultats identiques ?"
note "  Partie 2 — un fichier scellé le 2026-06-06 est-il reconstructible ?"
note ""
note "Cet outil mesure et consigne. Il n'interprète pas les résultats."
note "Un écart est enregistré tel quel et l'exécution se poursuit."
note ""
note "Tout est écrit dans : $WORK"
note "Rien n'est installé ailleurs. Aucun mot de passe n'est demandé."
note "Pour tout effacer ensuite :  rm -rf $WORK"
echo
printf '  Appuyez sur Entrée pour commencer (Ctrl+C pour annuler) '
read -r _ || true

# ---------- plateforme ----------
titre "ENVIRONNEMENT"
SYS="$(uname -s)"; ARCH="$(uname -m)"
case "$SYS/$ARCH" in
  Linux/x86_64)  MAMBA_PLAT="linux-64" ;;
  Darwin/x86_64) MAMBA_PLAT="osx-64" ;;
  Darwin/arm64)  MAMBA_PLAT="osx-arm64" ;;
  *) note "Système : $SYS $ARCH"
     abandon "Plateforme non couverte. Attendu : Linux x86_64, macOS x86_64 ou macOS arm64." ;;
esac
CPU="$(processeur)"; AVX="$(avx512)"
note "Système    : $SYS $ARCH"
note "Processeur : $CPU"
note "AVX-512    : $AVX"
note "Python     : $(python3 --version 2>&1)"

for outil in git curl python3 tar; do
  command -v "$outil" >/dev/null 2>&1 || abandon "Outil requis absent : $outil"
done
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || \
  abandon "Aucun utilitaire de calcul d'empreinte disponible (sha256sum ou shasum)."

mkdir -p "$WORK" || abandon "Répertoire de travail non créable : $WORK"
cd "$WORK" || abandon "Accès impossible à $WORK"
{
  echo "KAIROS — DONNÉES D'ATTESTATION"
  echo "Genere le      : $(date -u '+%Y-%m-%d %H:%M:%S') UTC"
  echo "Systeme        : $SYS $ARCH"
  echo "Detail         : $(uname -a)"
  echo "Processeur     : $CPU"
  echo "AVX-512        : $AVX"
  echo "Python systeme : $(python3 --version 2>&1)"
  echo "Repertoire     : $WORK"
  echo
} > "$ATT"

# =============================================================================
titre "PARTIE 1 — SUBSTRAT NUMÉRIQUE"
# =============================================================================
note "Kairos publie douze empreintes obtenues par ses propres mesures."
note "Cette partie les recalcule sur votre machine."

etape "Étape 1 — récupération du vérificateur depuis le dépôt public"
cmd "git clone $REPO"
rm -rf "$WORK/KV"
git clone -q "$REPO" "$WORK/KV" || abandon "Clone du dépôt impossible."
OBT="$(sha256 "$WORK/KV/determinism_ladder.py")"
note ""
note "Empreinte du fichier téléchargé :"
compare "Empreinte du verificateur" "$SCRIPT_ATTENDU" "$OBT"
echo "determinism_ladder.py : $OBT" >> "$ATT"

etape "Étape 2 — préparation de l'environnement de calcul"
cmd "python3 -m venv env  puis  pip install -r requirements.txt"
note "  (numpy, pandas, xgboost — quelques dizaines de secondes)"
cd "$WORK/KV" || abandon "Accès impossible à $WORK/KV"
if pyver_ok; then
  note "  python3 du système : $(python3 --version 2>&1) — utilisable"
  python3 -m venv env >/dev/null 2>&1 || abandon "Création de l'environnement Python impossible."
  PY1="$WORK/KV/env/bin/python3"
  PIP1="$WORK/KV/env/bin/pip"
  VOIE1="venv sur python3 du système"
else
  note "  python3 du système : $(python3 --version 2>&1) — hors enveloppe 3.10 à 3.12"
  note "  Les mesures publiées portent sur Python 3.10 à 3.12."
  note "  Un interpréteur 3.12 est installé dans le répertoire de travail."
  export MAMBA_ROOT_PREFIX="$WORK/.mamba"
  get_micromamba || abandon "Téléchargement de micromamba impossible ($MAMBA_PLAT)."
  OMPPKG=""
  [ "$SYS" = "Darwin" ] && OMPPKG="llvm-openmp"
  "$WORK/bin/micromamba" create -y -p "$WORK/py312" python=3.12 pip $OMPPKG -c conda-forge >/dev/null 2>&1 || \
    abandon "Création de l'interpréteur 3.12 impossible."
  PY1="$WORK/py312/bin/python"
  PIP1="$WORK/py312/bin/pip"
  VOIE1="micromamba python 3.12"
  cd "$WORK/KV" || abandon "Accès impossible à $WORK/KV"
fi
"$PIP1" install --quiet -r requirements.txt >/dev/null 2>&1 || \
  abandon "Installation des bibliothèques impossible."
VP1="$("$PY1" -c 'import sys,numpy,pandas;print(sys.version.split()[0],numpy.__version__,pandas.__version__)' 2>/dev/null)"
note "  environnement prêt — $VOIE1"
note "  python/numpy/pandas : $VP1"
echo "Partie 1 — voie : $VOIE1" >> "$ATT"
echo "Partie 1 — python/numpy/pandas : $VP1" >> "$ATT"

etape "Étape 3 — exécution dans l'enveloppe déclarée"
cmd "OPENBLAS_CORETYPE=Haswell OMP_NUM_THREADS=1 ... python3 determinism_ladder.py"
OPENBLAS_CORETYPE=Haswell \
OMP_NUM_THREADS=1 MKL_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 \
PYTHONHASHSEED=0 \
"$PY1" determinism_ladder.py > "$WORK/ladder.txt" 2>&1 || \
  abandon "Exécution du vérificateur impossible. Voir $WORK/ladder.txt"

note ""
P1_OK=0; P1_KO=0
echo "--- Partie 1 : empreintes ---" >> "$ATT"
while read -r niveau publie; do
  [ -z "$niveau" ] && continue
  obtenu="$(awk -v n="$niveau" '$1==n { for(i=2;i<=NF;i++) if ($i ~ /^[0-9a-f]{16}$/) { print $i; exit } }' "$WORK/ladder.txt")"
  [ -z "$obtenu" ] && obtenu="(non lu)"
  if [ "$publie" = "$obtenu" ]; then etat="identique"; P1_OK=$((P1_OK+1))
  else etat="DIFFÉRENT"; P1_KO=$((P1_KO+1)); fi
  printf '  %-5s publie %s   obtenu %s   %s\n' "$niveau" "$publie" "$obtenu" "$etat"
  echo "$niveau publie=$publie obtenu=$obtenu" >> "$ATT"
done <<< "$LADDER_ATTENDU"

L6VALS="$(awk '$1=="L6" { for(i=2;i<=NF;i++) if ($i ~ /^[0-9a-f]{16}$/) { print $i; break } }' "$WORK/ladder.txt")"
i=0
for v in $L6VALS; do
  i=$((i+1))
  if [ "$v" = "e05c0b80de5ce5e4" ]; then etat="identique"; P1_OK=$((P1_OK+1))
  else etat="DIFFÉRENT"; P1_KO=$((P1_KO+1)); fi
  printf '  %-5s publie e05c0b80de5ce5e4   obtenu %s   %s\n' "L6.$i" "$v" "$etat"
  echo "L6 mesure $i : publie=e05c0b80de5ce5e4 obtenu=$v" >> "$ATT"
done
if [ "$i" -lt 2 ]; then
  manque=$((2-i)); P1_KO=$((P1_KO+manque))
  printf '  %-5s publie e05c0b80de5ce5e4   obtenu (non lu)   DIFFÉRENT\n' "L6"
  echo "L6 : $manque mesure(s) non lue(s) — xgboost absent ou en echec" >> "$ATT"
fi
note ""
note "  Partie 1 — $P1_OK empreintes identiques sur 12."
echo "Partie 1 : $P1_OK identiques / 12" >> "$ATT"


etape "Étape 4 — mesure sans la variable OPENBLAS_CORETYPE"
note "  Le même calcul est relancé sans cette variable. Le résultat est"
note "  consigné sans interprétation."
OMP_NUM_THREADS=1 MKL_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 PYTHONHASHSEED=0 \
"$PY1" determinism_ladder.py > "$WORK/ladder_sans.txt" 2>/dev/null
L3S="$(awk '$1=="L3" { for(i=2;i<=NF;i++) if ($i ~ /^[0-9a-f]{16}$/) { print $i; exit } }' "$WORK/ladder_sans.txt")"
note ""
note "  L3 avec la variable : $(awk '$1=="L3" { for(i=2;i<=NF;i++) if ($i ~ /^[0-9a-f]{16}$/) { print $i; exit } }' "$WORK/ladder.txt")"
note "  L3 sans la variable : ${L3S:-(non lu)}"
{ echo "--- Partie 1 : sans OPENBLAS_CORETYPE ---"
  echo "L3 sans OPENBLAS_CORETYPE : ${L3S:-non lu}"; } >> "$ATT"

# =============================================================================
titre "PARTIE 2 — REJEU D'UN FICHIER SCELLÉ"
# =============================================================================
note "Kairos publie l'empreinte d'un fichier enregistré le 2026-06-06, produit"
note "à partir d'un jeu de données scientifique public."
note "Cette partie le reconstruit sur votre machine."

etape "Étape 1 — téléchargement du jeu de données depuis sa source d'origine"
cmd "curl -o BBBP.csv $CSV_URL"
note "  Ce fichier provient de DeepChem, pas de Kairos."
mkdir -p "$WORK/rejeu" || abandon "Répertoire de rejeu non créable."
cd "$WORK/rejeu" || abandon "Accès impossible au répertoire de rejeu."
curl -sL -o BBBP.csv "$CSV_URL" || abandon "Téléchargement du jeu de données impossible."
OBT="$(sha256 BBBP.csv)"
note ""
compare "Empreinte du jeu de donnees" "$CSV_ATTENDU" "$OBT"
echo "BBBP.csv : $OBT" >> "$ATT"

etape "Étape 2 — environnement de reconstruction"
note "  L'empreinte du fichier produit dépend des versions exactes des"
note "  bibliothèques. L'environnement requis est :"
note "     Python 3.10 · pandas 1.5.3 · pyarrow 23.0.0 · numpy < 2"
note ""
note "  micromamba est téléchargé dans ce répertoire uniquement."
note "  Aucune installation système, aucun droit administrateur."
cmd "micromamba create -p ./env310 python=3.10 pip   [$MAMBA_PLAT]"
export MAMBA_ROOT_PREFIX="$WORK/.mamba"
get_micromamba || abandon "Téléchargement de micromamba impossible ($MAMBA_PLAT)."
cd "$WORK/rejeu" || abandon "Accès impossible au répertoire de rejeu."
"$WORK/bin/micromamba" create -y -p "$WORK/rejeu/env310" python=3.10 pip -c conda-forge >/dev/null 2>&1 || \
  abandon "Création de l'environnement de reconstruction impossible."
"$WORK/rejeu/env310/bin/pip" install --quiet \
  "pandas==1.5.3" "pyarrow==23.0.0" "numpy<2" >/dev/null 2>&1 || \
  abandon "Installation de pandas/pyarrow impossible."
VP2="$("$WORK/rejeu/env310/bin/python" -c \
  'import sys,pandas,pyarrow,numpy;print(sys.version.split()[0],pandas.__version__,pyarrow.__version__,numpy.__version__)')"
note ""
note "  Environnement obtenu — python/pandas/pyarrow/numpy : $VP2"
{ echo "--- Partie 2 : environnement ---"
  echo "plateforme micromamba : $MAMBA_PLAT"
  echo "python/pandas/pyarrow/numpy : $VP2"; } >> "$ATT"

etape "Étape 3 — reconstruction du fichier"
note "  Trois instructions de bibliothèques publiques, aucun composant Kairos :"
cmd "read_csv → Table.from_pandas → write_table(compression='snappy')"
"$WORK/rejeu/env310/bin/python" - > "$WORK/rejeu/sortie.txt" 2>&1 <<'PYEOF'
import pandas as pd, pyarrow as pa, pyarrow.parquet as pq, hashlib
df = pd.read_csv("BBBP.csv", low_memory=False)
print("lignes:", len(df))
pq.write_table(pa.Table.from_pandas(df), "bbbp.parquet", compression="snappy")
print("sha256:", hashlib.sha256(open("bbbp.parquet","rb").read()).hexdigest())
PYEOF
LIGNES="$(awk '/^lignes:/ {print $2}' "$WORK/rejeu/sortie.txt")"
OBT="$(awk '/^sha256:/ {print $2}' "$WORK/rejeu/sortie.txt")"
[ -z "$OBT" ] && abandon "La reconstruction n'a produit aucun fichier. Voir $WORK/rejeu/sortie.txt"
note ""
note "  Lignes lues : ${LIGNES:-?}   (2050 publiées)"
note ""
compare "Empreinte du fichier reconstruit" "$PARQUET_ATTENDU" "$OBT"
{ echo "Lignes lues : ${LIGNES:-?} (2050 publiees)"
  echo "bbbp.parquet : $OBT"; } >> "$ATT"

# =============================================================================
titre "SYNTHÈSE DES MESURES"
# =============================================================================
note "Partie 1 — échelle de déterminisme : $P1_OK empreintes identiques sur 12"
note "Empreintes de fichiers  : $CONFORMES identiques, $ECARTS différentes"
note "  (vérificateur, jeu de données, fichier reconstruit)"
note ""
note "Cet outil ne qualifie pas ces résultats. L'interprétation relève du"
note "protocole, qui précise ce qui est attendu selon l'environnement."
{ echo
  echo "--- SYNTHESE ---"
  echo "Partie 1 (echelle) : $P1_OK identiques / 12"
  echo "Empreintes de fichiers : $CONFORMES identiques, $ECARTS differentes"
  echo "Aucune interpretation n'est faite par l'outil."; } >> "$ATT"

titre "ET MAINTENANT"
note "Toutes les mesures sont consignées dans :"
note ""
note "    $ATT"
note ""
note "Reportez ces valeurs dans le modèle d'attestation du protocole,"
note "puis datez et signez."
note ""
note "Vous attestez avoir exécuté ces opérations et observé ces résultats."
note "Rien de plus. Vous ne certifiez ni ne validez Kairos Systems."
note ""
note "Question ou écart : security@kairossystems.ch"
note "Pour tout effacer :  rm -rf $WORK"
echo
exit 0