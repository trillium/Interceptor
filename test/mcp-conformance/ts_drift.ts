/**
 * Prints the reference server's known verb keys (classification + menus) as JSON.
 * The conformance drift check compares this to the Python port.
 */
import { knownVerbKeys } from "../../cli/mcp/drift"

console.log(JSON.stringify(knownVerbKeys()))
