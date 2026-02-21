// https://docs.expo.dev/guides/using-eslint/
const { defineConfig } = require('eslint/config');
const expoConfig = require('eslint-config-expo/flat');

module.exports = defineConfig([
  expoConfig,
  {
    ignores: ['dist/*'],
    rules: {
      // TS + Metro alias '@/*' resolves at compile/runtime; eslint import resolver is not configured here.
      'import/no-unresolved': 'off',
    },
  },
]);
