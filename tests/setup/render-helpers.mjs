import React from "react";
import { render } from "ink-testing-library";
import stripAnsi from "strip-ansi";

/**
 * jac2ink standalone compiles often emit positional-arg Ink functions.
 * Wrap them so ink-testing-library can pass a props object.
 *
 * @param {(...args: unknown[]) => unknown} Component
 * @param {string[]} propNames
 * @param {Record<string, unknown>} [defaults]
 */
export function wrapPositional(Component, propNames, defaults = {}) {
  function Wrapped(props) {
    const args = propNames.map((name) => {
      if (name in props) return props[name];
      if (name in defaults) return defaults[name];
      return undefined;
    });
    return Component(...args);
  }
  Wrapped.displayName = `${Component.name}Ink`;
  return Wrapped;
}

/** Positional Jac export that already accepts a single props object. */
export function asPropsComponent(Component) {
  return Component;
}

/**
 * @param {React.ComponentType<any>} Component
 * @param {Record<string, unknown>} props
 */
export function renderInk(Component, props = {}) {
  const { lastFrame, unmount } = render(React.createElement(Component, props));
  return {
    frame() {
      return stripAnsi(lastFrame() ?? "");
    },
    rawFrame() {
      return lastFrame() ?? "";
    },
    unmount,
  };
}
