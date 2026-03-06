#/bin/bash

if [ -z "${APP}" ]
    echo "No app is set for conversion"
fi

./dylibify Payload/$APP.app/$APP $APP
codesign -fs- $APP
mv $APP Payload/$APP.app/$APP
xattr -cr Payload/$APP.app

pushd Payload/$APP.app

vtool -set-build-version maccatalyst 11.0 14.0 -replace -output $APP $APP

pushd Frameworks
for f in *.framework; do
    pushd $f
    FRAMEWORK_NAME=$(basename $f .framework)
    vtool -set-build-version maccatalyst 11.0 14.0 -replace -output $FRAMEWORK_NAME $FRAMEWORK_NAME
    codesign -fs- $FRAMEWORK_NAME
    popd
done

for f in *.dylib; do 
    vtool -set-build-version maccatalyst 11.0 14.0 -replace -output $f $f
    codesign -fs- $f
done

popd
popd
