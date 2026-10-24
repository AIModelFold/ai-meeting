#!/bin/zsh
# 会议助手一键启动：在终端里运行 ./start.sh（可加 --lang zh / --lang en / --no-translate / --no-window）
cd "$(dirname "$0")"
[ -x capture ] || swiftc -O capture.swift -o capture
[ -x translate ] || swiftc -O translate.swift -o translate
[ -x subtitle ] || swiftc -O subtitle.swift -o subtitle
exec node run.mjs "$@"
