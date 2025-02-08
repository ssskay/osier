#!/bin/zsh

# Build the app
echo "Building OpenSuperWhisper..."
xcodebuild -scheme OpenSuperWhisper -configuration Debug -jobs 8 -derivedDataPath Build -quiet -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation -UseModernBuildSystem=YES -clonedSourcePackagesDirPath SourcePackages -skipUnavailableActions CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO OTHER_CODE_SIGN_FLAGS="--entitlements OpenSuperWhisper/OpenSuperWhisper.entitlements" build | xcpretty --simple --color

# Check if build was successful
if [ $? -eq 0 ]; then
    echo "Building successful! Starting the app..."
    
    # Remove quarantine attribute if exists
    xattr -d com.apple.quarantine ./Build/Build/Products/Debug/OpenSuperWhisper.app 2>/dev/null || true
    
    # Run the app and show logs
    ./Build/Build/Products/Debug/OpenSuperWhisper.app/Contents/MacOS/OpenSuperWhisper
else
    echo "Build failed!"
    exit 1
fi 