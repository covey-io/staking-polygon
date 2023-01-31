const { deployProxy } = require('@openzeppelin/truffle-upgrades');

const CoveyStaking = artifacts.require('CoveyStaking');

module.exports = async function (deployer) {
    const instance = await deployProxy(
        CoveyStaking,
        ['0xC8E20DFab79Ed91252c97b9bE81E21Da678Afb07'],
        {
            deployer,
        }
    );
    console.log('Deployed', instance.address);
};
