import { BottomTabBarButtonProps } from '@react-navigation/bottom-tabs';
import { PlatformPressable } from '@react-navigation/elements';
import * as Haptics from 'expo-haptics';
import React from 'react';
import { StyleSheet } from 'react-native';

import { useUIAppearance } from '@/lib/uiAppearance';

export function HapticTab(props: BottomTabBarButtonProps) {
  const focused = props.accessibilityState?.selected;
  const { touchOutline } = useUIAppearance();
  const [touchHover, setTouchHover] = React.useState(false);
  const showOutline = touchOutline && touchHover;

  return (
    <PlatformPressable
      {...props}
      style={[
        props.style as any,
        styles.button,
        focused ? styles.buttonActive : null,
        showOutline ? styles.buttonTouchHover : null,
      ]}
      onPressIn={(ev) => {
        setTouchHover(true);
        if (process.env.EXPO_OS === 'ios') {
          // Add a soft haptic feedback when pressing down on the tabs.
          Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
        }
        props.onPressIn?.(ev);
      }}
      onPressOut={(ev) => {
        setTouchHover(false);
        props.onPressOut?.(ev);
      }}
    />
  );
}

const styles = StyleSheet.create({
  button: {
    flex: 1,
    marginHorizontal: 2,
    marginVertical: 0,
    borderRadius: 20,
    alignItems: 'center',
    justifyContent: 'center',
  },
  buttonActive: {
    backgroundColor: 'rgba(255,255,255,0.10)',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.28)',
  },
  buttonTouchHover: {
    borderWidth: 1,
    borderColor: '#bfe5ff',
    backgroundColor: 'rgba(170,220,255,0.14)',
    shadowColor: '#7ecbff',
    shadowOpacity: 0.28,
    shadowRadius: 10,
    shadowOffset: { width: 0, height: 0 },
  },
});
