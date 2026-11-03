#!/usr/bin/env bash
# One-off voice-cloning job phases. Invoked by .github/workflows/clone-tts.yml
# Phases: ref | deps | model | synth | report-failure
# Raw audio lives ONLY in $TMP (runner temp, outside the repo). Anything
# committed under clone-task/out/ is either a text marker or SMIME-encrypted.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TMP="${CLONE_TMP:-/tmp/clone-task}"
mkdir -p "$TMP" clone-task/out
BRANCH="${CLONE_BRANCH:-arena/e599117f-audio-cloning}"
set -a; . clone-task/config.env; set +a

utc() { date -u +%FT%TZ; }
set_phase() { printf '%s %s\n' "$1" "$(utc)" > "$TMP/.phase"; echo "== phase: $1 =="; }

push_out() {
  local msg="$1"
  echo "push_out: status before add:"; git status --short clone-task/out || true
  git add -A clone-task/out
  echo "push_out: staged:"; git diff --cached --stat || true
  if git diff --cached --quiet; then echo "push_out: nothing new"; return 0; fi
  git commit -q -m "$msg"
  git fetch -q origin "$BRANCH"
  if ! git rebase -q "origin/$BRANCH"; then git rebase --abort || true; echo "push_out: rebase failed"; return 1; fi
  git push -q origin "HEAD:$BRANCH"
  git fetch -q origin "$BRANCH"
  echo "push_out: pushed ($msg); remote out tree:"
  git ls-tree -r --name-only "origin/$BRANCH" -- clone-task/out || true
}

verify() { # file, expected: sha256hex | size:N
  local f="$1" exp="$2"
  if [[ "$exp" == size:* ]]; then
    [ "$(stat -c%s "$f")" = "${exp#size:}" ]
  else
    echo "$exp  $f" | sha256sum -c - >/dev/null 2>&1
  fi
}

dl() { # url dest expected
  local url="$1" dest="$2" exp="$3" i
  mkdir -p "$(dirname "$dest")"
  for i in 1 2 3; do
    echo ">> download $(basename "$dest") (try $i)"
    if curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 -o "$dest.tmp" "$url" \
       && mv "$dest.tmp" "$dest" && verify "$dest" "$exp"; then
      echo "   ok $(basename "$dest") $(stat -c%s "$dest") bytes"; return 0
    fi
    echo "   FAILED try $i for $(basename "$dest")"; sleep 5
  done
  return 1
}

phase_ref() {
  set_phase ref
  local src="$TMP/src_audio.bin" i
  for i in 1 2 3; do
    if curl -fsSL --retry 3 --connect-timeout 30 -o "$src" \
        "https://drive.usercontent.google.com/download?id=${DRIVE_FILE_ID}&export=download&confirm=t"; then
      break
    fi
    echo "reference download try $i failed"; sleep 5
  done
  if [ "$(stat -c%s "$src" 2>/dev/null || echo 0)" != "$SRC_SIZE" ]; then
    echo "ERROR: reference size mismatch: got $(stat -c%s "$src" 2>/dev/null || echo 0), want $SRC_SIZE"
    head -c 300 "$src" 2>/dev/null | strings | head -5 || true
    return 1
  fi
  if ! verify "$src" "$SRC_SHA256"; then echo "ERROR: reference sha256 mismatch"; return 1; fi
  echo "reference source verified (size+sha256)"
  printf 'utc=%s\nsrc_size=%s\nsrc_sha256_ok=1\n' "$(utc)" "$SRC_SIZE" > clone-task/out/REF_DOWNLOADED
  # Signal FIRST (agent revokes the temporary Drive link on this marker),
  # then do the ffmpeg work locally.
  push_out "clone-task: REF_DOWNLOADED [bot]"
  if ! command -v ffmpeg >/dev/null 2>&1; then
    sudo apt-get update -qq && sudo apt-get install -y -qq ffmpeg
  fi
  local fos
  fos="$(awk -v L="$REF_LEN" 'BEGIN{printf "%.2f", L-0.01}')"
  ffmpeg -hide_banner -loglevel error -y -ss "$REF_START" -t "$REF_LEN" -i "$src" \
    -ac 1 -ar 24000 -af "afade=t=in:st=0:d=0.01,afade=t=out:st=${fos}:d=0.01" \
    -c:a pcm_s16le "$TMP/reference.wav"
  test -s "$TMP/reference.wav"
  echo "reference.wav ready: $(stat -c%s "$TMP/reference.wav") bytes (start=${REF_START}s len=${REF_LEN}s)"
}

phase_deps() {
  set_phase deps
  python -m pip install -q --upgrade pip
  python -m pip install -q "onnxruntime>=1.19" "numpy>=2" "scipy>=1.5" \
    "soundfile>=0.12" "sentencepiece>=0.2.1" "typer>=0.12"
  python - <<'PY'
import onnxruntime, numpy, scipy, soundfile, sentencepiece, typer
print("deps ok:", "ort", onnxruntime.__version__, "| numpy", numpy.__version__,
      "| scipy", scipy.__version__, "| soundfile", soundfile.__version__)
PY
}

phase_model() {
  set_phase model
  local onnx="https://huggingface.co/Nimaone/pocket-tts-farsi-v2-onnx/resolve/main"
  local v2="https://huggingface.co/mehdi-hf/pocket-tts-farsi-v2/resolve/main"
  dl "$onnx/manifest.json"                 model/onnx/manifest.json                 size:3126
  dl "$onnx/flow_lm_step.onnx"             model/onnx/flow_lm_step.onnx             9c106f0c7668e1530ba67d85d102575f1072a430700834dd89822e87a8b2ae99
  dl "$onnx/flow_lm_step.onnx.data"        model/onnx/flow_lm_step.onnx.data        9e96f2765b2d382c2d026efa5e7945784e2e48c1c64d2c93b93027c810e9b43f
  dl "$onnx/mimi_encoder.onnx"             model/onnx/mimi_encoder.onnx             5cf6de01264713069cccf2c3184ab2eda9f331cf466d9717a09246650d2beb72
  dl "$onnx/mimi_encoder.onnx.data"        model/onnx/mimi_encoder.onnx.data        5b9cb71ad22714f4e89638d99e463f5db982d9b99840c466233463967ed9d90c
  dl "$onnx/mimi_decoder_step_kv.onnx"     model/onnx/mimi_decoder_step_kv.onnx     1058f97ddc1eaf97a410d38160ab4d20519ccec916c262f1c3cac63ba355bbac
  dl "$onnx/mimi_decoder_step_kv.onnx.data" model/onnx/mimi_decoder_step_kv.onnx.data b85e3aef8fbe9d8981900a6148f5aaf12a38efa3a71aa5b93ffc06098cc938f5
  dl "$onnx/g2p_encoder.onnx"              model/onnx/g2p_encoder.onnx              00881d15876c54c8e49e2ed95579468dfc2387fd43060a93de7209087edbe2bd
  dl "$onnx/g2p_decoder.onnx"              model/onnx/g2p_decoder.onnx              fa80894dbe8fbc353356af8c589bb0a12181a56404540eadbcd2a462917a0e69
  dl "$onnx/g2p_decoder.onnx.data"         model/onnx/g2p_decoder.onnx.data         d0162d6d54eddc1b7f879d97797e131507e5f53568a74bbc38be9f51ab6f95d7
  dl "$onnx/weights.npz"                   model/onnx/weights.npz                   cc365f19311301e5cb54537a4c8efd815ac4dc7783d7f96475a73c3e665fa329
  dl "$onnx/decode_state_init.npz"         model/onnx/decode_state_init.npz         62eb32c8d1a83010e23cff40827d1fafd49c6a97ba21ccdcc9b8fa228f6afe26
  dl "$v2/tokenizer_ph.model"              model/v2/tokenizer_ph.model              603a537ad7d369aa7077b6c0fd20aaad86658448e59c4d1b0050e4c01a22fbed
  dl "$v2/normalize_fa.py"                 model/v2/normalize_fa.py                 size:14437
  printf 'utc=%s\nmodel_bytes=%s\n' "$(utc)" "$(du -sb model | cut -f1)" > clone-task/out/MODEL_READY
  push_out "clone-task: MODEL_READY [bot]"
}

wav_meta() { # wavpath -> key=value lines on stdout
  python - "$1" <<'PY'
import hashlib, sys
import numpy as np, soundfile as sf
p = sys.argv[1]
a, sr = sf.read(p)
h = hashlib.sha256(open(p, "rb").read()).hexdigest()
print(f"duration_s={len(a)/sr:.2f}")
print(f"sample_rate={sr}")
print(f"peak={float(np.abs(a).max()):.4f}")
print(f"rms={float(np.sqrt((a**2).mean())):.4f}")
print(f"finite={int(bool(np.isfinite(a).all())))}")
print(f"sha256={h}")
PY
}

phase_synth() {
  set_phase synth-smoke
  local smoke_text='سپس در ادامه گفت: بچّه‌ها، می‌دانید که ورزش برای سلامتی مفید است.'
  test -s "$TMP/reference.wav"
  test -s clone-task/text.txt
  echo "reference bytes: $(stat -c%s "$TMP/reference.wav")"
  echo "text bytes: $(wc -c < clone-task/text.txt) text sha256: $(sha256sum clone-task/text.txt | cut -d' ' -f1)"
  python scripts/tts_onnx.py "$smoke_text" "$TMP/reference.wav" "$TMP/smoke.wav" --seed 42
  test -s "$TMP/smoke.wav"
  wav_meta "$TMP/smoke.wav" > "$TMP/smoke_meta.txt"
  echo "--- smoke meta ---"; cat "$TMP/smoke_meta.txt"
  python - "$TMP/smoke.wav" <<'PY'
import sys, soundfile as sf, numpy as np
a, sr = sf.read(sys.argv[1]); d = len(a)/sr
assert np.isfinite(a).all() and 2.0 < d < 25.0, f"smoke check failed: dur={d}"
print(f"SMOKE OK duration={d:.2f}s")
PY
  set_phase synth-full
  local t0; t0="$(date +%s)"
  python scripts/tts_onnx.py "$(cat clone-task/text.txt)" "$TMP/reference.wav" "$TMP/result.wav" --seed "$SEED"
  test -s "$TMP/result.wav"
  local dt=$(( $(date +%s) - t0 ))
  wav_meta "$TMP/result.wav" > "$TMP/result_meta.txt"
  echo "--- result meta ---"; cat "$TMP/result_meta.txt"
  python - "$TMP/result_meta.txt" <<'PY'
import sys
meta = dict(line.split("=", 1) for line in open(sys.argv[1], encoding="utf-8") if "=" in line)
d = float(meta["duration_s"]); assert meta["finite"].strip() == "1", meta
assert 60.0 < d < 400.0, f"result duration out of expected range: {d}s"
print(f"RESULT CHECK OK duration={d:.2f}s")
PY
  {
    echo "utc=$(utc)"; echo "seed=$SEED"; echo "mode=split"
    echo "ref_start_s=$REF_START"; echo "ref_len_s=$REF_LEN"
    echo "synth_wall_s=$dt"; echo "[smoke]"; cat "$TMP/smoke_meta.txt"
    echo "[result]"; cat "$TMP/result_meta.txt"
  } > clone-task/out/RESULT_META.txt
  cat clone-task/out/RESULT_META.txt
  openssl smime -encrypt -binary -aes-256-cbc -outform DER \
    -in "$TMP/result.wav" -out clone-task/out/result.wav.enc clone-task/cert.pem
  openssl smime -encrypt -binary -aes-256-cbc -outform DER \
    -in "$TMP/smoke.wav" -out clone-task/out/smoke.wav.enc clone-task/cert.pem
  test -s clone-task/out/RESULT_META.txt
  test -s clone-task/out/result.wav.enc
  test -s clone-task/out/smoke.wav.enc
  echo "encrypted: result.wav.enc=$(stat -c%s clone-task/out/result.wav.enc) smoke.wav.enc=$(stat -c%s clone-task/out/smoke.wav.enc)"
  ls -lh "$TMP"/*.wav clone-task/out
  push_out "clone-task: RESULT encrypted [bot]"
  git fetch -q origin "$BRANCH"
  git ls-tree -r --name-only "origin/$BRANCH" -- clone-task/out | grep -qx 'clone-task/out/result.wav.enc'
  echo "VERIFIED: result.wav.enc present on remote branch"
}

phase_report_failure() {
  {
    echo "FAILED utc=$(utc)"
    echo "phase: $(cat "$TMP/.phase" 2>/dev/null || echo unknown)"
    echo "--- git log ---"; git log --oneline -3 2>/dev/null || true
    echo "--- phase.log tail (250 lines) ---"
    tail -n 250 "$TMP/phase.log" 2>/dev/null || echo "(no phase log)"
  } > clone-task/out/FAILED.txt
  push_out "clone-task: FAILED [bot]" || true
}

phase_diag() {
  {
    echo "DIAG utc=$(utc)"
    echo "phase: $(cat "$TMP/.phase" 2>/dev/null || echo unknown)"
    echo "--- ls TMP ---"; ls -lh "$TMP" 2>&1 || true
    echo "--- ls clone-task/out ---"; ls -lh clone-task/out 2>&1 || true
    echo "--- git status ---"; git status --short 2>&1 || true
    echo "--- git log ---"; git log --oneline -6 2>&1 || true
    echo "--- phase.log tail (300 lines) ---"
    tail -n 300 "$TMP/phase.log" 2>&1 || echo "(no phase log)"
  } > clone-task/out/DIAG.txt
  push_out "clone-task: DIAG [bot]" || true
}

case "${1:-}" in
  ref) phase_ref ;;
  deps) phase_deps ;;
  model) phase_model ;;
  synth) phase_synth ;;
  report-failure) phase_report_failure ;;
  diag) phase_diag ;;
  *) echo "usage: run.sh ref|deps|model|synth|report-failure|diag" >&2; exit 2 ;;
esac
