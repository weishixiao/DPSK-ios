# DPSK

DPSK 是一个本地 iOS 工作台: a Flutter app plus its own engine runtime, built to
run on-device without a desktop host. This repository is a private, personal
working copy derived from an AGPL-3.0 project; it is not distributed publicly.

## Layout

| Path | Contents |
| --- | --- |
| `app/` | Flutter application and the iOS Xcode project (Runner, ShareExtension, Widget, PhoneRunner) |
| `packages/` | Dart side packages used by the app |
| `runtime/` | Engine runtime sources (Node host, iSH guest, native bindings) |
| `tooling/` | Build and packaging scripts, including the iOS build pipeline |
| `docs/` | Design notes and operational documentation |

## Building

The iOS build runs through `tooling/ios/build.sh`, which wraps `flutter build ios`.
It expects a Flutter SDK (see `app/pubspec.yaml` for the pinned constraints) and the
Apple toolchain. CI does the same work in `.github/workflows/`.

## Licence

AGPL-3.0, inherited from the upstream project. See `LICENSE` and
`THIRD_PARTY_NOTICES.md`. Because the network copyleft applies, this tree is kept in a
private repository and is not offered as a network service to third parties.
