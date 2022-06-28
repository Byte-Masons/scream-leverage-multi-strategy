async function main() {
  const vaultAddress = '0xDFc089438B502a20516eA3515B722FbaEb853994';
  const ERC20 = await ethers.getContractFactory('@openzeppelin/contracts/token/ERC20/ERC20.sol:ERC20');
  const wantAddress = '0x21be370d5312f44cb42ce377bc9b8a0cef1a4c83';
  const want = await ERC20.attach(wantAddress);
  await want.approve(vaultAddress, ethers.utils.parseEther('100'));
  console.log('want approved');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
