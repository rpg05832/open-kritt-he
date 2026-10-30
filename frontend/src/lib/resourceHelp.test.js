import {describe,it,expect} from 'vitest';
import {resourceExplanation} from './resourceHelp.js';
describe('plain language resource explanations',()=>{
 it('distinguishes instructions from an installed static analysis tool',()=>{expect(resourceExplanation('Trail of Bits static analysis')).toContain('אינה מתקינה');});
 it('warns ordinary web users about blockchain-specific workflows',()=>{expect(resourceExplanation('Cosmos ABCI Panic Halt Review','workflow')).toContain('אינה מיועדת לאתר רגיל');});
});
