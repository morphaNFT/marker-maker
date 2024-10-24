const config = require("../config.json")

async function main() {
    const netWork = await ethers.provider.getNetwork();
    console.log("【networkId】:",netWork.chainId)

    const [deployer] = await ethers.getSigners();
    console.log("【deployer】:", await deployer.getAddress());

    const MarketMakerContract = await ethers.getContractFactory("MarketMaker");
    const MarketMaker = await MarketMakerContract.deploy(config.contract.seaport, config.contract.conduitAddress)
    await MarketMaker.deployed();
    console.log("【MarketMaker】:", MarketMaker.address);

    // owner转移
    let txTransferOwnership = await MarketMaker.transferOwnership(config.newPotentialOwner)
    await txTransferOwnership.wait()
    console.log("【txTransferOwnership】:", txTransferOwnership.hash)
}


main()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });