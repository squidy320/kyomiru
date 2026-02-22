import React from 'react';
import { StyleProp, ViewStyle } from 'react-native';

import LiquidGlassView from '@/components/liquid-glass-view';

type GlassSurfaceProps = {
  children?: React.ReactNode;
  style?: StyleProp<ViewStyle>;
  enabled?: boolean;
  effect?: 'regular' | 'clear' | 'none';
};

export default function GlassSurface({
  children,
  style,
  enabled = true,
  effect = 'regular',
}: GlassSurfaceProps) {
  return (
    <LiquidGlassView enabled={enabled} interactive={false} effect={effect} style={style}>
      {children}
    </LiquidGlassView>
  );
}
