// Minimal deployment script for testing
async function main() {
  console.log('Mock deployment script');
  console.log(
    'WRFToken deployed to: 0x5FbDB2315678afecb367f032d93F642f64180aa3'
  );
  console.log('Deployment completed successfully');
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
