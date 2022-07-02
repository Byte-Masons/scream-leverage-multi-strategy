async function main() {
  const vaultAddress = '0xcdA5deA176F2dF95082f4daDb96255Bdb2bc7C7D';
  const ERC20 = await ethers.getContractFactory('@openzeppelin/contracts/token/ERC20/ERC20.sol:ERC20');
  const wantAddress = '0x04068DA6C83AFCFA0e13ba15A6696662335D5B75';
  const want = await ERC20.attach(wantAddress);
  await want.approve(vaultAddress, ethers.BigNumber.from(1000000000));
  console.log('want approved');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
