#!/usr/bin/env bash
exec "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/run_one.sh" c 8 control c8
