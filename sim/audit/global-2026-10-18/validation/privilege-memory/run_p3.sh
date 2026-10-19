#!/usr/bin/env bash
exec "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/run_one.sh" p 3 control p3
