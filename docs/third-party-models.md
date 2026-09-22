# Bundled third-party model

The macOS 12/13 foreground-segmentation fallback bundles Apple's compact
`DeepLabV3Int8LUT.mlmodel` model.

- Source page: <https://developer.apple.com/machine-learning/models/>
- Direct source URL: <https://ml-assets.apple.com/coreml/models/Image/ImageSegmentation/DeepLabV3/DeepLabV3Int8LUT.mlmodel>
- Download size: 2,252,685 bytes (about 2.3 MB)
- Model input: RGB image, 513 × 513 pixels
- Model output: `semanticPredictions`, a 513 × 513 Int32 class map
- Model metadata: Pascal VOC-style classes with class `0` reserved for background

The file is kept unchanged in the application source tree and compiled by
Xcode into `DeepLabV3Int8LUT.mlmodelc`. The model metadata points to the
TensorFlow and TensorFlow Models repositories for the original model and
license information; retain this notice whenever redistributing the fork.

There is no runtime download. On macOS 14 and newer the existing Vision
foreground-instance implementation remains the primary path; this model is
used only by the legacy compatibility backend and its deterministic fallbacks.
