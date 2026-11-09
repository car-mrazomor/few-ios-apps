# MinnetCam

iOS app that recognizes what you point the camera at, live and fully on device.
Runs [minnet](https://github.com/car-mrazomor/minnet), a CNN written from scratch in C, trained on CIFAR-10.

## Build

```sh
brew install xcodegen
xcodegen generate
open MinnetCam.xcodeproj
```

`scripts/sync-minnet.sh` copies the engine and model from `../minnet`.
`scripts/build-ipa.sh` builds an unsigned `.ipa` for sideloading.
