const { upgradeProxy } = require('@openzeppelin/truffle-upgrades');
const CoveyStaking = artifacts.require('CoveyStaking');

module.exports = async function (deployer) {
    const existing = await CoveyStaking.deployed();
    const instance = await upgradeProxy(existing.address, CoveyStaking, {
        deployer,
    });

    console.log('Deployed', instance.address);
};
