/** Minimal Jac dict stand-in for compiled components that call `.get()`. */
export function jacDict(record) {
  return {
    get(key, defaultValue = undefined) {
      if (Object.prototype.hasOwnProperty.call(record, key)) {
        return record[key];
      }
      return defaultValue;
    },
  };
}
