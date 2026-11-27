import sys

if sys.argv[1:2] == ["preflight-corpus"]:
    from .preflight import main
    raise SystemExit(main(sys.argv[2:]))

from .inspector import main

raise SystemExit(main())
