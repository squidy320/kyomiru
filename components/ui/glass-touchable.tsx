import React from 'react';
import { StyleProp, TouchableOpacity, TouchableOpacityProps, ViewStyle } from 'react-native';

import LiquidGlassView from '@/components/liquid-glass-view';

type GlassTouchableProps = TouchableOpacityProps & {
  containerStyle?: StyleProp<ViewStyle>;
  glassEnabled?: boolean;
  effect?: 'regular' | 'clear' | 'none';
};

export default function GlassTouchable({
  children,
  containerStyle,
  style,
  glassEnabled = true,
  effect = 'regular',
  ...touchableProps
}: GlassTouchableProps) {
  return (
    <LiquidGlassView enabled={glassEnabled} interactive={false} effect={effect} style={containerStyle}>
      <TouchableOpacity {...touchableProps} style={style}>
        {children}
      </TouchableOpacity>
    </LiquidGlassView>
  );
}
