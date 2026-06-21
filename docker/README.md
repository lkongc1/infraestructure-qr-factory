# docker/

Dockerfiles for local development and testing of the QR Factory Lambda handler
(and, in the future, the SPA frontend) without provisioning AWS resources.
A typical image would replicate the Lambda runtime (Node.js 20.x, arm64) so the
handler in `../src/index.mjs` can be invoked locally with the same dependencies
listed in `../src/package.json`.

This directory is a placeholder; no Dockerfiles are shipped yet.
