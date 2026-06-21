# docker/

Dockerfiles for local development and testing of the QR Factory Lambda handler
(and, in the future, the SPA frontend) without provisioning AWS resources.
A typical image would replicate the Lambda runtime (Python 3.11, arm64) so the
handler in `../src/qr_generator.py` can be invoked locally with the same
dependencies listed in `../src/requirements.txt`.

This directory is a placeholder; no Dockerfiles are shipped yet.
