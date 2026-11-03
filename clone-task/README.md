# clone-task (temporary, one-off)

One-off voice-cloning job for the repository owner, run via GitHub Actions
(`.github/workflows/clone-tts.yml`). The job downloads the ONNX model
package from HuggingFace, synthesizes `text.txt` with a 5-second reference
clip, and commits back **AES-256/SMIME-encrypted** audio
(`out/*.enc`, encrypted to `cert.pem`; the private key is not in this repo).

This folder and the workflow are removed once the result is delivered.
Triggered only by pushing a change to `clone-task/GO` on the session branch.
