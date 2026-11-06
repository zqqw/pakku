## Version of the argv protocol spoken between pakku and the helpers in `lib/`.
##
## Bump it whenever the argument layout changes. A helper left over from an
## older installation in `PKGLIBDIR` would otherwise read the new arguments with
## the old meaning and half-perform an install before failing.
const helperProtocol* = 1
