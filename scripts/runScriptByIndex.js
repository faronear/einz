#!/usr/bin/env node
// npm run todo —— 列出 package.json 的所有脚本，按序号选择并运行
const fs = require('fs');
const path = require('path');
const readline = require('readline');

const packageJsonPath = path.join(__dirname, '..', 'package.json');
const scripts = Object.entries(JSON.parse(fs.readFileSync(packageJsonPath, 'utf8')).scripts);

scripts.forEach(([name, command], index) => {
  console.log(`${index + 1}. ${name}  =>  ${command}`);
});

const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
rl.question('输入序号运行对应脚本: ', (answer) => {
  rl.close();
  const index = parseInt(answer, 10) - 1;
  if (!(index >= 0 && index < scripts.length)) {
    console.error(`无效序号: ${answer}`);
    process.exit(1);
  }
  const [name] = scripts[index];
  console.log(`\n> npm run ${name}\n`);
  const child = require('child_process').spawn('npm', ['run', name], { stdio: 'inherit' });
  child.on('exit', (code) => process.exit(code));
});
