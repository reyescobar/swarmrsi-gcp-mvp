# How to Contribute

Contributions to this project are welcome and must be accompanied by a
Contributor License Agreement (CLA). You (or your employer) retain the
copyright to your contribution; this simply gives permission to use and
redistribute your contributions as part of the project.

Visit <https://cla.developers.google.com/> to inspect current agreements or
sign a new one.

## Before Opening a Pull Request

1. Run the offline verification and 4-gate sabotage suite:
   ```bash
   make test-local
   ./scripts/03_run_showcase.sh
   ```
2. Ensure modified files retain `SPDX-License-Identifier: Apache-2.0` headers and introduce no hardcoded credentials or project-specific identifiers.
