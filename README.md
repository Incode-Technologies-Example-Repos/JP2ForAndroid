# Incode JP2 for Android
---------------------------
An open-source JPEG-2000 image encoder/decoder for Android based on [OpenJPEG](http://www.openjpeg.org/) v2.5.4.

This fork starts from [Thales JP2ForAndroid 1.1.0](https://github.com/ThalesGroup/JP2ForAndroid/tree/1.1.0), commit `8ad43abb5d8e2caf2147162d3bfe5569581b5d1f`.
It uses the Java package `com.incode.jp2` and the native library `libincode-openjpeg.so`.
The native library exports only its JNI entry points and preserves 16 KB page alignment on all four Android ABIs.

## Build the Incode artifact

Use JDK 17, Android SDK 36, NDK `23.2.8568313`, and CMake `3.22.1`.
The library supports Android API 16 and later. The test app uses API 23 and later.

```sh
./gradlew :jp2-android:assembleRelease
./gradlew :jp2-android:publishReleasePublicationToStagingRepository
```

The release AAR is `library/build/outputs/aar/jp2-android-release.aar`.
The second command creates a local Maven repository under `build/staging-repo`. It does not upload artifacts.

## Build with GitHub Actions

The **Build decoder AAR** workflow runs on pushes and pull requests.
It uses the same Java, Android SDK, NDK, and CMake versions as the local build.
It builds the release AAR, runs Android lint, and creates the Maven staging repository.

Open the workflow run in the repository's **Actions** tab.
Download `jp2-android-<commit>` from **Artifacts**.
The download contains the AAR, Maven metadata, sources JAR, SHA-256 checksum, and source commit.
After the workflow reaches the default branch, **Run workflow** also starts it manually.
If Actions is disabled for the fork, a repository administrator must enable it first.

The workflow needs no Maven credentials. It uploads build results to GitHub Actions only.
It does not publish to Nexus or GitHub Packages. Native device tests run separately with the commands below.
To publish a downloaded build, use its `build/staging-repo` directory with the publication commands below.
Published versions are immutable. If a rebuilt artifact has different bytes, publish it with a new version.

## Publish locally

Store these credentials in `~/.gradle/gradle.properties` or environment variables with the same names:

| Repository | Username key | Password key |
| --- | --- | --- |
| Nexus | `nexus_username` | `nexus_password` |
| GitHub Packages | `github_username` | `github_pat` |

The GitHub token needs `write:packages` scope and write access to `Incode-Technologies-Example-Repos/android-omni-packages`.
Keep credential values outside this repository.

Create the staging repository with the command above.
For a new version, first run `./gradlew clean` to remove earlier staged versions.
Before an upload, run both conflict checks:

Set `JP2_NEXUS_URL` to the internal Maven releases repository URL before running these commands.

```sh
bash scripts/uploadStagedRepo.sh build/staging-repo "$JP2_NEXUS_URL" nexus_username nexus_password --check-only
bash scripts/uploadStagedRepo.sh build/staging-repo https://maven.pkg.github.com/incode-technologies-example-repos/android-omni-packages github_username github_pat --check-only
```

After both checks pass, upload the same staged files to both repositories:

```sh
bash scripts/uploadStagedRepo.sh build/staging-repo "$JP2_NEXUS_URL" nexus_username nexus_password --immutable
bash scripts/uploadStagedRepo.sh build/staging-repo https://maven.pkg.github.com/incode-technologies-example-repos/android-omni-packages github_username github_pat --immutable
```

The uploader rejects existing version files with different bytes and downloads each uploaded file to verify its contents.
If an upload stops partway, rerun it with the same staging directory.
The scripts use the staged-file publication process from the Incode Android SDK.
Local publication does not require Bitrise.

## Native tests

Connect an Android device or start an emulator, then run the existing codec tests:

```sh
./gradlew :jp2-android:connectedDebugAndroidTest
./gradlew :testapp:connectedDebugAndroidTest
```

The test app also contains keiji 1.0.5 to exercise coexistence with a real second decoder.
That dependency does not ship in the release AAR or its Maven metadata.
Run the coexistence test in separate processes for each library load order:

```sh
./gradlew :testapp:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.incode.jp2.test.TestDecoderCoexistence#testBothDecodersPreservePixels -Pandroid.testInstrumentationRunnerArguments.decoderLoadOrder=incodeFirst
./gradlew :testapp:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.incode.jp2.test.TestDecoderCoexistence#testBothDecodersPreservePixels -Pandroid.testInstrumentationRunnerArguments.decoderLoadOrder=originalFirst
```

To test the release AAR as a Maven dependency, first create the local Maven repository with the publication command above.
Then add `-PcodecFromStaging=true` to either test app command.

Local verification on 2026-10-23 passed all 26 upstream codec tests and both coexistence tests on ARM64 emulators:

- Android 14 with 4 KB pages.
- Android 15 with 16 KB pages.

The staged release AAR passed both decoder loading orders on both emulators.
ELF alignment passed for all four ABIs, and the test app APK passed `zipalign -c -P 16 4`.
SDK integration tests passed with synthetic JP2, raw J2K, and JPEG portraits on a 16 KB emulator.
API 23 runtime tests and protected SDK release tests remain pending.

## Set up
Add dependency to your `build.gradle`:
```groovy
implementation 'com.incode.sdk:jp2-android:1.1.0-incode.1'
```

## Basic Usage
Decoding an image:
```java
import com.incode.jp2.JP2Decoder;

Bitmap bmp = new JP2Decoder(jp2data).decode();
imgView.setImageBitmap(bmp);
```
Encoding an image:
```java
import com.incode.jp2.JP2Encoder;

Bitmap bmp = ...;
//lossless encode
byte[] jp2data = new JP2Encoder(bmp).encode();
//lossy encode (target PSNR = 50dB)
byte[] jp2data = new JP2Encoder(bmp)
                     .setVisualQuality(50)
                     .encode();
```

## Advanced Usage
### Multiple Resolutions
A single JPEG-2000 image can contain multiple resolutions.
The final resolution is always equal to `<image_width> x <image_height>`; each
additional resolution reduces the width and height by the factor of two. If you 
don't need the full resolution, you can save memory and decoding time by
decoding at a lower resolution.

#### Encoding
Default number of resolutions is 6, but you can specify your own value:
```java
byte[] jp2data = new JP2Encoder(bmp)
                     .setNumResolutions(3)
                     .encode();
```
The number of resolutions must be between 1 and 32 and both image width and height
must be greater or equal to `2^(numResolutions - 1)`.

#### Decoding
You can obtain the number of resolutions (as well as some other information 
about the image) by calling the `readHeader()` method:
```java
Header header = new JP2Decoder(jp2data).readHeader();
int numResolutions = header.numResolutions;
```
If you don't need the full resolution image, you can skip one or more
resolutions during the decoding process.
```java
Bitmap reducedBmp = new JP2Decoder(jp2data)
                        .setSkipResolutions(2)
                        .decode();
```



### Multiple Quality Layers
Multiple layers can be encoded in a JPEG-2000 image, each having a different
visual quality. If you don't need maximum visual quality, you can save 
decoding time by skipping the higher-quality layers.


#### Encoding
Quality layers can be specified in two ways: as a list of compression ratios 
or visual qualities. The **compression ratios** are specified as factors of compression, 
i.e. 20 means the size will be 20 times less than the raw uncompressed size. 
Compression ratio 1 means lossless compression. Example:
```java
byte[] jp2data = new JP2Encoder(bmp)
                     //specify 3 quality layers with compression ratios 1:50, 1:20, and lossless.
                     .setCompressionRatio(50, 10, 1)
                     .encode();
```

**Visual quality** is specified as [PSNR](https://en.wikipedia.org/wiki/Peak_signal-to-noise_ratio) 
values in dB. Usable values are roughly between 20 (very
aggressive compression) and 70 (almost lossless). Special value 0 indicates
lossless compression. Example:
```java
byte[] jp2data = new JP2Encoder(bmp)
                     //specify 3 quality layers with PSNR 30dB, 50dB, and lossless.
                     .setVisualQuality(30, 50, 0)
                     .encode();
```

`setCompressionRatio()` and `setVisualQuality()` can not be used at the same time.


#### Decoding
You can obtain the number of available quality layers by calling 
the `readHeader()` method:
```java
Header header = new JP2Decoder(jp2data).readHeader();
int numQualityLayers = header.numQualityLayers;
```

If you don't need a maximum quality image, you can trade some visual quality 
for a shorter decoding time by not decoding all the quality layers.
```java
Bitmap lowQualityBmp = new JP2Decoder(jp2data)
                           .setLayersToDecode(2)
                           .decode();
```

### Decoding Area
If you don't want to decode the whole image, you can set the decoding area to only decode a part of it.

You can obtain the dimensions of the image by calling the `readHeader()` method:
```java
Header header = new JP2Decoder(jp2data).readHeader();
int imgWidth = header.width;
int imgHeight = header.height;
```

Then you can set the area to be decoded.
```java
Bitmap topLeftQuarterBmp = new JP2Decoder(jp2data)
                               .setDecodingArea(Rect(0,0,imgWidth/2,imgHeight/2))
                               .decode();
```


### File Format
`JP2Encoder` supports two output formats:
* JP2 - standard JPEG-2000 file format (encapsulating a JPEG-2000 codestream)
* J2K - unencapsulated JPEG-2000 codestream

JP2 is the default output format, but it can be changed:
```java
byte[] j2kdata = new JP2Encoder(bmp)
                     .setOutputFormat(FORMAT_J2K)
                     .encode();
```

[High-Throughput JPEG-2000](https://jpeg.org/jpeg2000/htj2k.html) (or HTJ2K) is supported for decoding only.
