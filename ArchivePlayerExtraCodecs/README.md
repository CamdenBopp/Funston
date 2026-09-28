# ArchivePlayerExtraCodecs

Optional, independent Swift package containing an FFmpeg **build-policy audit**, not decoder integration. It ships no FFmpeg source, headers or binaries and links no FFmpeg libraries. The core and app do not depend on or import it.

```sh
swift test --package-path ArchivePlayerExtraCodecs
swift run --package-path ArchivePlayerExtraCodecs audit-ffmpeg-build /absolute/config.h /absolute/config_components.h 946fcce07b6dcd0331c8cc609192aeff5e1924f8
```

See [the investigation and external build recipe](../Docs/OptionalCodecs.md). Audit success only validates the submitted configuration text; it does not authenticate binaries or certify licensing compliance. No codec fallback becomes available by adding this package.
