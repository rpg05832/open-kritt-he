import fs from 'node:fs/promises';
import {PrismaClient} from '@prisma/client';
const p=new PrismaClient();
const body=JSON.parse(await fs.readFile('/tmp/automaticWorkflow.json','utf8'));
const skills=JSON.parse(await fs.readFile('/tmp/automaticSkills.json','utf8'));
await p.$transaction(async tx=>{
const existing=await tx.workflow.findFirst({where:{name:body.name},orderBy:{insertedAt:'asc'}});
if(existing){const scans=await tx.scan.findMany({where:{workflowId:existing.id}});if(scans.some(s=>!['completed','stopped','failed'].includes(s.status)))throw new Error('Active scan: preset upgrade postponed');
const oldSteps=await tx.step.findMany({where:{id:{in:existing.stepIds}}});
for(const scan of scans)await tx.scan.update({where:{id:scan.id},data:{extras:{...(scan.extras||{}),workflow_before_upgrade:{name:existing.name,description:existing.description,steps:oldSteps.map(s=>({id:String(s.id),name:s.name,content:s.content,depth:s.depth}))}}}});
for(const level of body.levels){const step=oldSteps.find(s=>s.depth===level.depth);if(!step)throw new Error('Unexpected workflow structure');await tx.step.update({where:{id:step.id},data:{name:level.steps[0].name,content:level.steps[0].content}});}
await tx.workflow.update({where:{id:existing.id},data:{description:body.description}});
}
for(const skill of skills){const found=await tx.agentSkill.findUnique({where:{slug:skill.slug}});if(!found)await tx.agentSkill.create({data:{...skill,sourceUrl:null}});}
});
console.log('Current preset upgraded; completed scan outputs preserved; skills installed.');await p.$disconnect();
