import {PrismaClient} from '@prisma/client';
import {summarizeExpectedWorkflowLineages} from './src/lib/repo.js';
const p=new PrismaClient();
const m=await p.stepMetadata.findMany({where:{scanId:1n,kind:'step'},select:{stepId:true,prevId:true,prevTable:true,repeatRun:true,status:true}});
const r=await p.stepResult.findMany({where:{scanId:1n},select:{id:true,stepId:true,prevId:true,prevTable:true,repeatRun:true}});
const scan=await p.scan.findUnique({where:{id:1n}});const w=await p.workflow.findUnique({where:{id:scan.workflowId}});const steps=await p.step.findMany({where:{id:{in:w.stepIds}}});
console.log(JSON.stringify({summary:summarizeExpectedWorkflowLineages(scan,steps,m,r),metadata:m,results:r},(k,v)=>typeof v==='bigint'?String(v):v));await p.$disconnect();
