console.error("npm start does not run Inbox agents.");
console.error("Use npm run worker:local for an intentional local legacy-worker run.");
console.error("Use npm run trigger:dev to develop managed Inbox tasks.");
process.exitCode = 1;
