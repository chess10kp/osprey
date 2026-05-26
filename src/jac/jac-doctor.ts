// Jac environment detection — delegates to lib/jac/jac/doctor via toolchain bridge.

export type { JacDoctorReport } from "./jac-bridge.js";
export { bridgeRunJacDoctor as runJacDoctor } from "./jac-bridge.js";
