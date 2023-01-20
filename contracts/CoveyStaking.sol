// contracts/CoveyStaking.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";

contract CoveyStaking is Initializable, AccessControlUpgradeable {
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;

    bytes32 public constant DISPENSER = keccak256("DISPENSER");
    IERC20 public stakingToken;
    struct StakeInfo {
      address staker;
      uint256 stakedAmount;
    }
    EnumerableSetUpgradeable.AddressSet internal stakers;
    address[] public pendingUnstakers;

    mapping(address => uint256) public stakedAmounts;
    mapping(address => uint256) public unstakedAmounts;

    event Staked(address indexed _adr, uint256 amount, uint256 totalStakedAmount);
    
    event Unstaked(address indexed _adr, uint256 amount, uint256 totalUnstakedAmount);

    event CancelledUnstake(address indexed _adr);

    event Bankrupt(address indexed _adr, uint256 amountLost);

    event StakeDispensed(address indexed _adr, uint256 amountDispensed);

    modifier onlyOwner {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not owner");
        _;
    }

    modifier onlyOwnerOrDispenser {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender) ||
            hasRole(DISPENSER, msg.sender),
            "Only owner or dispenser"
        );
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IERC20 _stakingToken) public initializer {
        __AccessControl_init();
        stakingToken = _stakingToken;
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function stake(uint256 amount) external {
        require(amount != 0, "0 amount");
        stakingToken.transferFrom(msg.sender, address(this), amount);
        // if recognised as first time staker, push to staker list
        if (!stakers.contains(msg.sender)) stakers.add(msg.sender);
        uint256 totalStakedAmount = stakedAmounts[msg.sender] + amount;
        stakedAmounts[msg.sender] = totalStakedAmount;
        emit Staked(msg.sender, amount, totalStakedAmount);
    }

    function unstake(uint256 amount) external {
        require(amount != 0, "0 amount");
        uint256 totalUnstakedAmount = unstakedAmounts[msg.sender] + amount;
        require(stakedAmounts[msg.sender] >= totalUnstakedAmount, "Unstaking too large");
        // add to pending unstaker list
        // if user unstaking for first time since dispenseStakes() was called
        // checking (totalUnstakedAmount == amount) instead of (unstakedAmounts[msg.sender] == 0)
        // is more gas efficient because it avoids an SLOAD
        if (totalUnstakedAmount == amount) {
            pendingUnstakers.push(msg.sender);
        }
        unstakedAmounts[msg.sender] = totalUnstakedAmount;
        emit Unstaked(msg.sender, amount, totalUnstakedAmount);
    }

    /// @dev iterates through pendingUnstakers, might run out of gas
    function cancelUnstake() external {
        require(unstakedAmounts[msg.sender] > 0, "0 unstake");
        delete unstakedAmounts[msg.sender];
        uint256 numUnstakers = pendingUnstakers.length;
        for (uint i; i < numUnstakers; ++i) {
            if (pendingUnstakers[i] == msg.sender) {
                pendingUnstakers[i] = pendingUnstakers[numUnstakers - 1];
                pendingUnstakers.pop();
                break;
            }
        }
        emit CancelledUnstake(msg.sender);
    }

    /// @dev more gas efficient by taking in the index to avoid iterating through pendingUnstakers
    function cancelUnstake(uint256 index) external {
        require(unstakedAmounts[msg.sender] > 0, "0 unstake");
        delete unstakedAmounts[msg.sender];
        require(pendingUnstakers[index] == msg.sender, "Wrong index");
        pendingUnstakers[index] = pendingUnstakers[pendingUnstakers.length - 1];
        pendingUnstakers.pop();
        emit CancelledUnstake(msg.sender);
    }

    function dispenseStakes() external onlyOwnerOrDispenser {
        // iterate through pendingUnstakers list
        uint256 numUnstakers = pendingUnstakers.length;
        address unstaker;
        uint256 unstakeAmount;
        for(uint256 i; i < numUnstakers; ++i) {
            unstaker = pendingUnstakers[i];
            unstakeAmount = unstakedAmounts[unstaker];
            stakedAmounts[unstaker] = stakedAmounts[unstaker] - unstakeAmount;
            delete unstakedAmounts[unstaker];

            // remove from staking list if user has 0 stake after unstaking
            if (stakedAmounts[unstaker] == 0) stakers.remove(unstaker);

            stakingToken.transfer(unstaker, unstakeAmount);
            emit StakeDispensed(unstaker, unstakeAmount);
        }
        // finally, reset pendingUnstakers list
        delete pendingUnstakers;
    }

    /// @param indices array of indices of bankruptAddresses in the pendingUnstaker array
    /// value will be ignored if bankruptAddress has no pending unstakes
    /// @dev indices to be of same length as bankruptAddresses
    function bankruptStakers(
        address bankruptciesReceiver,
        address[] calldata bankruptAddresses,
        uint256[] calldata indices
    ) external onlyOwnerOrDispenser {
        uint256 bankruptAddressesLength = bankruptAddresses.length;
        require(bankruptAddressesLength == indices.length, "length mismatch");
        address bankruptAddress;
        uint256 stakedAmount;
        for (uint i = 0; i < bankruptAddressesLength; ++i) {
            bankruptAddress = bankruptAddresses[i];
            stakedAmount = stakedAmounts[bankruptAddress];

            // remove from pendingUnstaker list if bankruptAddress has a pending unstake
            // subsequently zeroes unstakedAmounts mapping
            if (unstakedAmounts[bankruptAddress] > 0) {
                require(pendingUnstakers[indices[i]] == bankruptAddress, "wrong index");
                pendingUnstakers[indices[i]] = pendingUnstakers[pendingUnstakers.length - 1];
                pendingUnstakers.pop();
                delete unstakedAmounts[bankruptAddress];
            }

            // remove from stakedAmounts mapping
            delete stakedAmounts[bankruptAddress];

            // remove from stakers list
            stakers.remove(bankruptAddress);

            // transfer stakedAmount to specified receiver address
            stakingToken.transfer(bankruptciesReceiver, stakedAmount);
            emit Bankrupt(bankruptAddress, stakedAmount);
        }
    }

    function getNetStaked(address staker) public view returns (uint) {
        return stakedAmounts[staker] - unstakedAmounts[staker];
    }

    function getAllNetStaked() external view returns (StakeInfo[] memory stakeInformation) {
        uint256 numStakers = stakers.length();
        stakeInformation = new StakeInfo[](numStakers);
        address staker;
        for(uint256 i; i < numStakers; ++i) {
            staker = stakers.at(i);
            stakeInformation[i] = StakeInfo({
                staker: staker,
                stakedAmount: getNetStaked(staker)
            });
        }
    }

    function delegateDispenser(address _addr) external onlyOwner {
        grantRole(DISPENSER, _addr);
    }

    function revokeDispenser(address _addr) external onlyOwner {
        revokeRole(DISPENSER, _addr);
    }

    function getPendingUnstakers() public view returns(address[] memory _pendingUnstakers) {
        return pendingUnstakers;
    }

    function getStakers() public view returns(address[] memory  _stakers) {
        return stakers.values();
    }
}
