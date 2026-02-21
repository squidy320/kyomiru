import React from 'react';
import { StyleProp, View, ViewProps, ViewStyle } from 'react-native';
import { GlassView } from 'expo-glass-effect';

import { useUIAppearance } from '@/lib/uiAppearance';

type LiquidGlassViewProps = ViewProps & {
  effect?: 'regular' | 'clear' | 'none';
  interactive?: boolean;
  enabled?: boolean;
  style?: StyleProp<ViewStyle>;
};

export default function LiquidGlassView({
  children,
  effect = 'regular',
  interactive = true,
  enabled = true,
  style,
  ...rest
}: LiquidGlassViewProps) {
  const { liquidGlassActive } = useUIAppearance();

  if (!enabled || !liquidGlassActive) {
    return (
      <View style={style} {...rest}>
        {children}
      </View>
    );
  }

  return (
    <GlassView glassEffectStyle={effect} isInteractive={interactive} style={style} {...rest}>
      {children}
    </GlassView>
  );
}
