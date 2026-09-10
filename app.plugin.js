/**
 * Expo config plugin for react-native-nitro-wakeword.
 *
 * app.json:
 *   "plugins": [
 *     ["react-native-nitro-wakeword", {
 *       "microphonePermission": "Allow $(PRODUCT_NAME) to listen for the wake word.",
 *       "iosBackgroundAudio": false,
 *       "androidForegroundService": false,
 *       "modelsDir": "assets/wakeword"
 *     }]
 *   ]
 *
 * Every `*.onnx` file in `modelsDir` (relative to the project root) is copied
 * into the native projects on `expo prebuild`:
 *   - Android: android/app/src/main/assets/<file>
 *   - iOS:     ios/WakeWordModels/<file>, added to "Copy Bundle Resources"
 * so it can be referenced by file name in `WakeWordModel.model`.
 */
const {
  withInfoPlist,
  withAndroidManifest,
  withDangerousMod,
  withXcodeProject,
  AndroidConfig,
  IOSConfig,
} = require('@expo/config-plugins');
const fs = require('fs');
const path = require('path');

const DEFAULT_MIC_TEXT =
  'Allow $(PRODUCT_NAME) to use the microphone for wake word detection.';
const DEFAULT_MODELS_DIR = 'assets/wakeword';
const IOS_GROUP = 'WakeWordModels';

function listModels(projectRoot, modelsDir) {
  const dir = path.resolve(projectRoot, modelsDir);
  if (!fs.existsSync(dir)) return [];
  return fs
    .readdirSync(dir)
    .filter((file) => file.toLowerCase().endsWith('.onnx'))
    .sort()
    .map((file) => ({ file, source: path.join(dir, file) }));
}

function withIosPermissions(config, { microphonePermission, iosBackgroundAudio }) {
  return withInfoPlist(config, (mod) => {
    mod.modResults.NSMicrophoneUsageDescription =
      microphonePermission ||
      mod.modResults.NSMicrophoneUsageDescription ||
      DEFAULT_MIC_TEXT;
    if (iosBackgroundAudio) {
      const modes = new Set(mod.modResults.UIBackgroundModes || []);
      modes.add('audio');
      mod.modResults.UIBackgroundModes = Array.from(modes);
    }
    return mod;
  });
}

function withAndroidPermissions(config, { androidForegroundService }) {
  return withAndroidManifest(config, (mod) => {
    const permissions = ['android.permission.RECORD_AUDIO'];
    if (androidForegroundService) {
      permissions.push(
        'android.permission.FOREGROUND_SERVICE',
        'android.permission.FOREGROUND_SERVICE_MICROPHONE',
        'android.permission.POST_NOTIFICATIONS',
      );
    }
    AndroidConfig.Permissions.ensurePermissions(mod.modResults, permissions);
    return mod;
  });
}

function withAndroidModels(config, modelsDir) {
  return withDangerousMod(config, [
    'android',
    (mod) => {
      const models = listModels(mod.modRequest.projectRoot, modelsDir);
      if (models.length === 0) return mod;
      const destDir = path.join(
        mod.modRequest.platformProjectRoot,
        'app',
        'src',
        'main',
        'assets',
      );
      fs.mkdirSync(destDir, { recursive: true });
      for (const { file, source } of models) {
        fs.copyFileSync(source, path.join(destDir, file));
      }
      return mod;
    },
  ]);
}

function withIosModels(config, modelsDir) {
  config = withDangerousMod(config, [
    'ios',
    (mod) => {
      const models = listModels(mod.modRequest.projectRoot, modelsDir);
      if (models.length === 0) return mod;
      const destDir = path.join(mod.modRequest.platformProjectRoot, IOS_GROUP);
      fs.mkdirSync(destDir, { recursive: true });
      for (const { file, source } of models) {
        fs.copyFileSync(source, path.join(destDir, file));
      }
      return mod;
    },
  ]);

  return withXcodeProject(config, (mod) => {
    const models = listModels(mod.modRequest.projectRoot, modelsDir);
    for (const { file } of models) {
      const filepath = path.join(IOS_GROUP, file);
      if (!fs.existsSync(path.join(mod.modRequest.platformProjectRoot, filepath))) {
        continue;
      }
      IOSConfig.XcodeUtils.addResourceFileToGroup({
        filepath,
        groupName: IOS_GROUP,
        project: mod.modResults,
        isBuildFile: true,
        verbose: false,
      });
    }
    return mod;
  });
}

module.exports = function withNitroWakeWord(config, props = {}) {
  const modelsDir = props.modelsDir || DEFAULT_MODELS_DIR;
  config = withIosPermissions(config, props);
  config = withAndroidPermissions(config, props);
  config = withAndroidModels(config, modelsDir);
  config = withIosModels(config, modelsDir);
  return config;
};
