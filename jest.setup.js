// Nitro creates HybridObjects through JSI, which does not exist under Jest.
// Tests install their own fake native object via NitroModules.createHybridObject.
jest.mock('react-native-nitro-modules', () => ({
  NitroModules: {
    createHybridObject: jest.fn(() => {
      throw new Error(
        'NitroModules.createHybridObject was not stubbed. Use makeFakeNative() from src/__tests__/utils/fakeNative.',
      );
    }),
  },
}));
