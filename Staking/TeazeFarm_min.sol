// SPDX-License-Identifier: MIT

// Teaze.Finance Staking Contract Version 1.0
// Stake your $teaze or LP tokens to receive SimpBux rewards (SBX)

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./SimpBux.sol";

interface ITeazePacks {
  function premint(address to, uint256 id) external;
  function getPackInfo(uint256 _packid) external view returns (uint256,uint256,uint256,uint256,bool,bool);
  function mintedCountbyID(uint256 _id) external view returns (uint256);
  function getPackIDbyNFT(uint256 _nftid) external returns (uint256);
  function packPurchased(address _recipient, uint256 _nftid) external; 
  function getPackTotalMints(uint256 _packid) external view returns (uint256);
  function getUserPackPrice(address _recipient, uint256 _packid) external view returns (uint256);
  function getPackTimelimitFarm(uint256 _nftid) external view returns (bool);
}

interface IDirectory {
    function getNFTMarketing() external view returns (address); 
    function getSBX() external view returns (address);
    function getLotto() external view returns (address);
    function getNFT() external view returns (address);
    function getPacks() external view returns (address);
    function getCrates() external view returns (address);
}

// Allows another user(s) to change contract variables
contract Authorized is Ownable {

    mapping(address => bool) public authorized;

    modifier onlyAuthorized() {
        require(authorized[_msgSender()] || owner() == address(_msgSender()), "E36");
        _;
    }

    function addAuthorized(address _toAdd) onlyOwner public {
        require(_toAdd != address(0), "E37");
        authorized[_toAdd] = true;
    }

    function removeAuthorized(address _toRemove) onlyOwner public {
        require(_toRemove != address(0), "E37");
        require(_toRemove != address(_msgSender()), "E38");
        authorized[_toRemove] = false;
    }

}

contract TeazeFarm is Ownable, Authorized, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardedAmount; //How many staked TEAZE tokens the user has withdrawn and gotten rewards for
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of SimpBux tokens
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accTeazePerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accTeazePerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. SimpBux tokens to distribute per block.
        uint256 lastRewardBlock; // Last block number that SimpBux tokens distribution occurs.
        uint256 accTeazePerShare; // Accumulated SimpBux tokens per share, times 1e12. See below.
        uint256 runningTotal; // Total accumulation of tokens (not including reflection, pertains to pool 1 ($Teaze))
    }

    SimpBux public immutable simpbux; // The SimpBux ERC-20 Token.
    uint256 private teazePerBlock; // SimpBux tokens distributed per block. Use getTeazePerBlock() to get the updated reward.

    PoolInfo[] public poolInfo; // Info of each pool.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo; // Info of each user that stakes LP tokens.
    mapping(address => bool) public addedLpTokens; // Used for preventing LP tokens from being added twice in add().
    mapping(uint256 => mapping(address => uint256)) public unstakeTimer; // Used to track time since unstake requested.
    mapping(address => uint256) private userBalance; // Balance of SimpBux for each user that survives staking/unstaking/redeeming.
    mapping(address => bool) private promoWallet; // Whether the wallet has received promotional SimpBux.
    mapping(address => uint256) private mintToken; // Whether the wallet has received a mint token from the lottery.
    mapping(uint256 =>mapping(address => bool)) public userStaked; // Denotes whether the user is currently staked or not. 
    
    uint256 public totalAllocPoint; // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public startBlock; // The block number when SimpBux token mining starts.

    uint256 public blockRewardUpdateCycle = 1 days; // The cycle in which the teazePerBlock gets updated.
    uint256 public blockRewardLastUpdateTime = block.timestamp; // The timestamp when the block teazePerBlock was last updated.
    uint256 public blocksPerDay = 28800; // The estimated number of mined blocks per day
    uint256 public blockRewardPercentage = 1; // The percentage used for teazePerBlock calculation.
    uint256 public unstakeFee = 1; //The percentage of Teaze tokens taken from staker at withdraw
    uint256 public noWaitFee = 2; //The percentage of Teaze tokens taken if staker doesn't want to wait for unstakeTime;
    uint256 public unstakeTime = 0; //86400; // Time in seconds to wait for withdrawal default (86400).
    uint256 public poolReward = 1000000000000; //starting basis for poolReward (default 1k).
    uint256 public stakeReward = 10000000000000000; //starting basis for stakeReward (default 10M).
    uint256 public rewardAmountLimit = 2100000000000000000; //users only get TEAZE rewards on first 2.1B staked to prevent draining rewards pool
    uint256 public minTeazeStake = 25000000000000000; //min stake amount (default 25 million Teaze).
    uint256 public maxTeazeStake = 2100000000000000000; //max stake amount (default 2.1 billion Teaze).
    uint256 public minLPStake = 250000000000000000; //min lp stake amount (default .25 LP tokens).
    uint256 public maxLPStake = 21000000000000000000; //max lp stake amount (default 21 LP tokens).
    uint256 public promoAmount = 200000000000; //amount of SimpBux to give to new stakers (default 200 SimpBux).
    uint256 public stakedDiscount = 30; //amount the price of a pack mint is discounted if the user is staked (default 30%). 
    uint256 public lottoSplit = 50; //amount of split to lotto (default 50%).
    uint256 public lootboxSplit = 50; //amount of split to lootbotx wallet (default 50%).
    
    uint256 public rewardSegment = poolReward.mul(100).div(200); //reward segment for dynamic staking.
    uint256 public ratio; //ratio of pool0 to pool1 for dynamic staking.
    uint256 public lpalloc = 50; //starting pool allocation for LP side.
    uint256 public stakealloc = 50; //starting pool allocation for Teaze side.
    uint256 public allocMultiplier = 5; //ratio * allocMultiplier to balance out the pools.

    uint256 public totalEarnedLoot; //Total amount of BNB sent for lootbox creation.
    uint256 public totalEarnedLotto; //Total amount of BNB used to buy token before being sent to stakepool.

    uint256 public simpCardRedeemDiscount = 10;

    IDirectory public directory;
    
    address public simpCardContract;

    bool simpCardBonusEnabled = false;
    bool public enableRewardWithdraw = false; //whether SimpBux is withdrawable from this contract (default false).
    bool public promoActive = false; //whether the promotional amount of SimpBux is given out to new stakers (default is True).
    
    event Unstake(address indexed user, uint256 indexed pid);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event WithdrawRewardsOnly(address indexed user, uint256 amount);

    constructor(
        SimpBux _simpbux,
        uint256 _startBlock,
        address _directory
    ) {
        require(address(_simpbux) != address(0), "E39");
        //require(_startBlock >= block.number, "startBlock is before current block");
        directory = IDirectory(_directory);
        simpbux = _simpbux;
        startBlock = _startBlock;
        addAuthorized(owner());

    }

    receive() external payable {}

    modifier updateTeazePerBlock() {
        (uint256 blockReward, bool update) = getTeazePerBlock();
        if (update) {
            teazePerBlock = blockReward;
            blockRewardLastUpdateTime = block.timestamp;
        }
        _;
    }

    function getTeazePerBlock() public view returns (uint256, bool) {
        if (block.number < startBlock) {
            return (0, false);
        }

        if (block.timestamp >= getTeazePerBlockUpdateTime() || teazePerBlock == 0) {
            return (poolReward.mul(blockRewardPercentage).div(100).div(blocksPerDay), true);
        }

        return (teazePerBlock, false);
    }

    function getTeazePerBlockUpdateTime() public view returns (uint256) {
        // if blockRewardUpdateCycle = 1 day then roundedUpdateTime = today's UTC midnight
        uint256 roundedUpdateTime = blockRewardLastUpdateTime - (blockRewardLastUpdateTime % blockRewardUpdateCycle);
        // if blockRewardUpdateCycle = 1 day then calculateRewardTime = tomorrow's UTC midnight
        uint256 calculateRewardTime = roundedUpdateTime + blockRewardUpdateCycle;
        return calculateRewardTime;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        bool _withUpdate
    ) public onlyOwner {
        require(address(_lpToken) != address(0), "E40");
        require(!addedLpTokens[address(_lpToken)], "E41");

        require(_allocPoint >= 1 && _allocPoint <= 100, "E42");

        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken : _lpToken,
            allocPoint : _allocPoint,
            lastRewardBlock : lastRewardBlock,
            accTeazePerShare : 0,
            runningTotal : 0 
        }));

        addedLpTokens[address(_lpToken)] = true;
    }

    // Update the given pool's SimpBux token allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) public onlyAuthorized {
        require(_allocPoint >= 1 && _allocPoint <= 100, "E42");

        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Update the given pool's SimpBux token allocation point when pool.
    function adjustPools(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) internal {
        require(_allocPoint >= 1 && _allocPoint <= 100, "E42");

        if (_withUpdate) {
            updatePool(_pid);
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // View function to see pending SimpBux tokens on frontend.
    function pendingSBXRewards(uint256 _pid, address _user) public view returns (uint256) {
        if(userStaked[_pid][_user]) {

            PoolInfo storage pool = poolInfo[_pid];
            UserInfo storage user = userInfo[_pid][_user];
            uint256 accTeazePerShare = pool.accTeazePerShare;
            uint256 lpSupply = stakeReward;
            uint256 useramount = user.amount;
            //uint256 lpSupply = pool.lpToken.balanceOf(address(this));
            
            if (block.number > pool.lastRewardBlock && lpSupply != 0) {
                uint256 multiplier = block.number.sub(pool.lastRewardBlock);
                (uint256 blockReward, ) = getTeazePerBlock();
                uint256 teazeReward = multiplier.mul(blockReward).mul(pool.allocPoint).div(totalAllocPoint);
                accTeazePerShare = accTeazePerShare.add(teazeReward.mul(1e12).div(lpSupply));
            }

            uint256 userbonus = 100;   

            if(_pid == 0) {
                uint256 result = useramount.mul(100).div(maxLPStake.div(2));
                if(result > 90) {
                    userbonus = 1;
                } else {
                    userbonus = userbonus.sub(result);
                    userbonus = userbonus.mul(11).div(100);
                }
                return (useramount.mul(accTeazePerShare).div(1e12).sub(user.rewardDebt)).mul(userbonus).mul(2).div(10);
            } else {
                uint256 result = useramount.mul(100).div(maxTeazeStake.div(2));
                if(result > 90) {
                    userbonus = 1;
                } else {
                    userbonus = userbonus.sub(result);
                    userbonus = userbonus.mul(11).div(100);
                }
                return (useramount.mul(accTeazePerShare).div(1e12).sub(user.rewardDebt)).mul(userbonus);
            }

        } else {
            return 0;
        }
                
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public onlyAuthorized {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date when lpSupply changes
    // For every deposit/withdraw pool recalculates accumulated token value
    function updatePool(uint256 _pid) public updateTeazePerBlock {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }

        //uint256 lpSupply = pool.runningTotal; 
        uint256 lpSupply = stakeReward;
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        uint256 multiplier = block.number.sub(pool.lastRewardBlock);
        uint256 teazeReward = multiplier.mul(teazePerBlock).mul(pool.allocPoint).div(totalAllocPoint);

        // no minting is required, the contract should have SimpBux token balance pre-allocated
        // accumulated SimpBux per share is stored multiplied by 10^12 to allow small 'fractional' values
        pool.accTeazePerShare = pool.accTeazePerShare.add(teazeReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    function updatePoolReward(uint256 _amount) public onlyAuthorized {
        poolReward = _amount;
    }

    // Deposit LP tokens/$Teaze to TeazeFarming for SimpBux token allocation.
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_msgSender()];

        updatePool(_pid);

        if (_amount > 0) {

            if(user.amount > 0) { //if user has already deposited, secure rewards before reconfiguring rewardDebt
                uint256 tempRewards = pendingSBXRewards(_pid, _msgSender());
                userBalance[_msgSender()] = userBalance[_msgSender()].add(tempRewards);
            }
            
            if (_pid != 0) { //$Teaze tokens
                if(user.amount == 0) { //we only want the minimum to apply on first deposit, not subsequent ones
                require(_amount >= minTeazeStake, "E43");
                }
                require(_amount.add(user.amount) <= maxTeazeStake, "E44");
                pool.runningTotal = pool.runningTotal.add(_amount);
                user.amount = user.amount.add(_amount);  
                pool.lpToken.safeTransferFrom(address(_msgSender()), address(this), _amount);

                
            } else { //LP tokens
                if(user.amount == 0) { //we only want the minimum to apply on first deposit, not subsequent ones
                require(_amount >= minLPStake, "E45");
                }
                require(_amount.add(user.amount) <= maxLPStake, "E46");
                pool.runningTotal = pool.runningTotal.add(_amount);
                user.amount = user.amount.add(_amount);
                pool.lpToken.safeTransferFrom(address(_msgSender()), address(this), _amount);
            }
            
            unstakeTimer[_pid][_msgSender()] = 9999999999;
            userStaked[_pid][_msgSender()] = true;

            if (!promoWallet[_msgSender()] && promoActive) {
                userBalance[_msgSender()] = userBalance[_msgSender()].add(promoAmount); //give 200 promo SimpBux
                promoWallet[_msgSender()] = true;
            }
         
            user.rewardDebt = user.amount.mul(pool.accTeazePerShare).div(1e12); 

            emit Deposit(_msgSender(), _pid, _amount);

        }
    }

    function setUnstakeTime(uint256 _time) external onlyAuthorized {

        require(_time >= 0 || _time <= 172800, "E47");
        unstakeTime = _time;
    }

    //Call unstake to start countdown
    function unstake(uint256 _pid) public {
        UserInfo storage user = userInfo[_pid][_msgSender()];
        require(user.amount > 0, "E48");

        uint256 tempRewards = pendingSBXRewards(_pid, _msgSender());
        userBalance[_msgSender()] = userBalance[_msgSender()].add(tempRewards);

        unstakeTimer[_pid][_msgSender()] = block.timestamp.add(unstakeTime);
        userStaked[_pid][_msgSender()] = false;

    }

    //Get time remaining until able to withdraw tokens
    function timeToUnstake(uint256 _pid, address _user) external view returns (uint256)  {

        if (unstakeTimer[_pid][_user] > block.timestamp) {
            return unstakeTimer[_pid][_user].sub(block.timestamp);
        } else {
            return 0;
        }
    }

    // Withdraw tokens from TeazeFarm
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_msgSender()];
        uint256 userAmount = user.amount;
        uint256 unstakerFee = 0;
        uint256 totalPercent = 100;
        uint finalAmount = 0;
        uint teazeamount = _amount;
        uint lpamount = _amount;
        require(_amount > 0, "E49");
        require(user.amount >= _amount, "E50");     

        updatePool(_pid);        

            if (_pid == 0) { //LP Tokens

                 if (unstakeTime == 0) {

                    unstakerFee = 0;
                    
                } else {

                    if (block.timestamp < unstakeTimer[_pid][_msgSender()]) {

                        unstakerFee = unstakeFee;
                    }

                }
                
                pool.runningTotal = pool.runningTotal.sub(lpamount);
                user.amount = user.amount.sub(lpamount);
                finalAmount = lpamount.mul(totalPercent.sub(unstakerFee)).div(100);
                pool.lpToken.safeTransfer(address(_msgSender()), finalAmount);
                emit Withdraw(_msgSender(), _pid, lpamount);

            } else { //Teaze tokens
 
                if (unstakeTime == 0) {

                    unstakerFee = unstakeFee;
                    
                } else {

                    if (block.timestamp > unstakeTimer[_pid][_msgSender()]) {
                        unstakerFee = noWaitFee;
                    } else {
                        unstakerFee = unstakeFee;
                    }

                }

                uint256 lpSupply = pool.lpToken.balanceOf(address(this)); //get total amount of tokens
                uint256 totalRewards = lpSupply.sub(pool.runningTotal); //get difference between contract address amount and ledger amount

                uint256 percentRewards = teazeamount.mul(100).div(pool.runningTotal); //get % of share out of 100
                uint256 reflectAmount = percentRewards.mul(totalRewards).div(100); //get % of reflect amount
            
                pool.runningTotal = pool.runningTotal.sub(teazeamount);
                user.amount = user.amount.sub(teazeamount);
                finalAmount = teazeamount.mul(totalPercent.sub(unstakerFee)).div(100).add(reflectAmount);
                pool.lpToken.safeTransfer(address(_msgSender()), finalAmount);
                emit Withdraw(_msgSender(), _pid, finalAmount);

            }
            

            if (userAmount == _amount) { //user is retrieving entire balance, set rewardDebt to zero
                user.rewardDebt = 0;
            } else {

                user.rewardDebt = user.amount.mul(pool.accTeazePerShare).div(1e12); 
                unstakeTimer[_pid][_msgSender()] = 9999999999;
                userStaked[_pid][_msgSender()] = true;

            }

            user.rewardedAmount = _amount;
                        
    }

    // Safe simpbux token transfer function, just in case if
    // rounding error causes pool to not have enough simpbux tokens
    function safeTokenTransfer(address _to, uint256 _amount) internal {
        uint256 balance = simpbux.balanceOf(address(this));
        uint256 amount = _amount > balance ? balance : _amount;
        simpbux.transfer(_to, amount);
    }

    function setBlockRewardUpdateCycle(uint256 _blockRewardUpdateCycle) external onlyAuthorized {
        require(_blockRewardUpdateCycle > 0, "E52");
        blockRewardUpdateCycle = _blockRewardUpdateCycle;
    }

    // Just in case an adjustment is needed since mined blocks per day
    // changes constantly depending on the network
    function setBlocksPerDay(uint256 _blocksPerDay) external onlyAuthorized {
        require(_blocksPerDay >= 1 && _blocksPerDay <= 28800, "E53");
        blocksPerDay = _blocksPerDay;
    }

    function setBlockRewardPercentage(uint256 _blockRewardPercentage) external onlyAuthorized {
        require(_blockRewardPercentage >= 1 && _blockRewardPercentage <= 100, "E54");
        blockRewardPercentage = _blockRewardPercentage;
    }

    // This will allow to rescue ETH sent by mistake directly to the contract
    function rescueETHFromContract() external onlyAuthorized {
        address payable _owner = payable(_msgSender());
        _owner.transfer(address(this).balance);
    }

    // Function to allow admin to claim *other* ERC20 tokens sent to this contract (by mistake)
    function transferERC20Tokens(address _tokenAddr, address _to, uint _amount) public onlyAuthorized {
       /* so admin can move out any erc20 mistakenly sent to farm contract EXCEPT Teaze & Teaze LP tokens */
        //require(_tokenAddr != address(0xcDC477f2ccFf2d8883067c9F23cf489F2B994d00), "Cannot transfer out LP token");
        //require(_tokenAddr != address(0x4faB740779C73aA3945a5CF6025bF1b0e7F6349C), "Cannot transfer out $Teaze token");
        IERC20(_tokenAddr).transfer(_to, _amount);
    }

    //returns total stake amount (LP, Teaze token) and address of that token respectively
    function getTotalStake(uint256 _pid, address _user) external view returns (uint256, IERC20) { 
         PoolInfo storage pool = poolInfo[_pid];
         UserInfo storage user = userInfo[_pid][_user];

        return (user.amount, pool.lpToken);
    }

    //gets the full ledger of deposits into each pool
    function getRunningDepositTotal(uint256 _pid) external view returns (uint256) { 
         PoolInfo storage pool = poolInfo[_pid];

        return (pool.runningTotal);
    }

    //gets the total of all pending rewards from each pool
    function getTotalpendingSBXRewards(address _user) public view returns (uint256) { 
        uint256 value1 = pendingSBXRewards(0, _user);
        uint256 value2 = pendingSBXRewards(1, _user);

        return value1.add(value2);
    }

    //gets the total amount of rewards secured (not pending)
    function getAccruedSBXRewards(address _user) external view returns (uint256) { 
        return userBalance[_user];
    }

    //gets the total of pending + secured rewards
    function getTotalSBXRewards(address _user) external view returns (uint256) { 
        uint256 value1 = getTotalpendingSBXRewards(_user);
        uint256 value2 = userBalance[_user];

        return value1.add(value2);
    }

    //moves all pending rewards into the accrued array
    function redeemTotalSBXRewards(address _user) internal { 

        uint256 pool0 = 0;

        PoolInfo storage pool = poolInfo[pool0];
        UserInfo storage user = userInfo[pool0][_user];

        updatePool(pool0);
        
        uint256 value0 = pendingSBXRewards(pool0, _user);
        
        userBalance[_user] = userBalance[_user].add(value0);

        user.rewardDebt = user.amount.mul(pool.accTeazePerShare).div(1e12); 

        uint256 pool1 = 1; 
        
        pool = poolInfo[pool1];
        user = userInfo[pool1][_user];

        updatePool(pool1);

        uint256 value1 = pendingSBXRewards(pool1, _user);
        
        userBalance[_user] = userBalance[_user].add(value1);

        user.rewardDebt = user.amount.mul(pool.accTeazePerShare).div(1e12); 
    }

    //whether to allow the SimpBux token to actually be withdrawn, of just leave it virtual (default)
    function enableRewardWithdrawals(bool _status) public onlyAuthorized {
        enableRewardWithdraw = _status;
    }

    //view state of reward withdrawals (true/false)
    function rewardWithdrawalStatus() external view returns (bool) {
        return enableRewardWithdraw;
    }

    //withdraw SimpBux
    function withdrawRewardsOnly() public nonReentrant {

        require(enableRewardWithdraw, "E55");

        IERC20 rewardtoken = IERC20(directory.getSBX()); //SimpBux

        redeemTotalSBXRewards(_msgSender());

        uint256 pending = userBalance[_msgSender()];
        if (pending > 0) {
            require(rewardtoken.balanceOf(address(this)) > pending, "E56");
            userBalance[_msgSender()] = 0;
            safeTokenTransfer(_msgSender(), pending);
        }
        
        emit WithdrawRewardsOnly(_msgSender(), pending);
    }

    //redeem the NFT with SimpBux only
    function redeem(uint256 _packid, bool _withMintToken) public nonReentrant {

        require(directory.getPacks() != address(0), "E57");
        require(ITeazePacks(directory.getPacks()).getPackTimelimitFarm(_packid), "E58");

        uint256 packMinted = ITeazePacks(directory.getPacks()).mintedCountbyID(_packid);
   
        (,,,uint256 packMintLimit,bool packRedeemable,) = ITeazePacks(directory.getPacks()).getPackInfo(_packid);
    
        require(packRedeemable, "E59");
        require(packMinted < packMintLimit, "E60");
         
        uint256 price = getSimpCardPackPrice(_packid, _msgSender());

        require(price > 0, "E61");

        if(_withMintToken) {

            require(mintToken[_msgSender()] > 0, "E62");
            mintToken[_msgSender()] = mintToken[_msgSender()] - 1;
            ITeazePacks(directory.getPacks()).premint(_msgSender(), _packid);

        } else { 

            redeemTotalSBXRewards(_msgSender());

            if (userBalance[_msgSender()] < price) {
            
                IERC20 rewardtoken = IERC20(directory.getSBX()); //SimpBux
                require(rewardtoken.balanceOf(_msgSender()) >= price, "E63"); 
                ITeazePacks(directory.getPacks()).premint(_msgSender(), _packid);
                IERC20(rewardtoken).transferFrom(_msgSender(), address(this), price);

            } else {

                require(userBalance[_msgSender()] >= price, "E64");
                ITeazePacks(directory.getPacks()).premint(_msgSender(), _packid);
                userBalance[_msgSender()] = userBalance[_msgSender()].sub(price);

            }

        }       

    }

    // users can also purchase the NFT with $teaze token and the proceeds can be split between nft creation address, lootbox contract, and the lotto pool
    function purchase(uint256 _packid) public payable nonReentrant {

        require(directory.getPacks() != address(0), "E57");
        require(ITeazePacks(directory.getPacks()).getPackTimelimitFarm(_packid), "E58");


        (,,,uint256 packMintLimit,, bool packPurchasable) = ITeazePacks(directory.getPacks()).getPackInfo(_packid);
        
        uint256 packMinted = ITeazePacks(directory.getPacks()).getPackTotalMints(_packid);

        uint256 price = getPackTotalPrice(_msgSender(), _packid);        

        require(packPurchasable, "E65");
        require(packMinted < packMintLimit, "E66");
        require(msg.value == price, "E67");
            
        ITeazePacks(directory.getPacks()).premint(_msgSender(), _packid);
        ITeazePacks(directory.getPacks()).packPurchased(_msgSender(),_packid);

        payable(directory.getLotto()).transfer(msg.value.mul(lottoSplit).div(100));
        totalEarnedLotto = totalEarnedLotto + msg.value.mul(lottoSplit).div(100);

        payable(directory.getCrates()).transfer(msg.value.mul(lootboxSplit).div(100));
        totalEarnedLoot = totalEarnedLoot + msg.value.mul(lootboxSplit).div(100);
        
    }

    
    // We can give the artists/influencers a SimpBux balance so they can redeem their own NFTs
    function setSimpBuxBalance(address _address, uint256 _amount) public onlyAuthorized {
        userBalance[_address] = _amount;
    }

    function reduceSimpBuxBalance(address _address, uint256 _amount) public onlyAuthorized {
        userBalance[_address] = userBalance[_address].sub(_amount);
    }

    function increaseSimpBuxBalance(address _address, uint256 _amount) public onlyAuthorized {
        userBalance[_address] = userBalance[_address].add(_amount);
    }

    function increaseSBXBalance(address _address, uint256 _amount) external {
        require(msg.sender == address(directory.getLotto()) || msg.sender == address(directory.getPacks()), "E68");
        userBalance[_address] = userBalance[_address].add(_amount);
    }


    // Get the holder rewards of users staked $teaze if they were to withdraw
    function getTeazeHolderRewards(address _address) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[1];
        UserInfo storage user = userInfo[1][_address];

        uint256 _amount = user.amount;

        if(_amount > 0) {

            return 0;

        } else {

            uint256 lpSupply = pool.lpToken.balanceOf(address(this)); //get total amount of tokens
            uint256 totalRewards = lpSupply.sub(pool.runningTotal); //get difference between contract address amount and ledger amount
        
            if (totalRewards > 0) { //include reflection
                uint256 percentRewards = _amount.mul(100).div(pool.runningTotal); //get % of share out of 100
                uint256 reflectAmount = percentRewards.mul(totalRewards).div(100); //get % of reflect amount

                return _amount.add(reflectAmount); //add pool rewards to users original staked amount

            } else {

                return 0;

            }
            
        }
 
    }

    // Sets min/max staking amounts for Teaze token
    function setTeazeStakingMinMax(uint256 _min, uint256 _max) external onlyAuthorized {

        require(_min < _max, "E69");
        require(_min > 0, "E70");

        minTeazeStake = _min;
        maxTeazeStake = _max;
    }

    // Sets min/max amounts for LP staking
    function setLPStakingMinMax(uint256 _min, uint256 _max) external onlyAuthorized {

        require(_min < _max, "E69");
        require(_min > 0, "E70");

        minLPStake = _min;
        maxLPStake = _max;
    }

    // Lets user move their pending rewards to accrued/escrow balance
    function moveRewardsToEscrow(address _address) external {

        require(_address == _msgSender() || authorized[_msgSender()], "E71");

        UserInfo storage user0 = userInfo[0][_msgSender()];
        uint256 userAmount = user0.amount;

        UserInfo storage user1 = userInfo[1][_msgSender()];
        userAmount = userAmount.add(user1.amount);

        if (userAmount == 0) {
            return;
        } else {
            redeemTotalSBXRewards(_msgSender());
        }       
    }

    // Sets true/false for the SimpBux promo for new stakers
    function setPromoStatus(bool _status) external onlyAuthorized {
        promoActive = _status;
    }


    // Sets the allocation multiplier
    function setAllocMultiplier(uint256 _newAllocMul) external onlyAuthorized {

        require(_newAllocMul >= 1 && _newAllocMul <= 100, "E42");

        allocMultiplier = _newAllocMul;
    }

    function setAllocations(uint256 _lpalloc, uint256 _stakealloc) external onlyAuthorized {

        require(_lpalloc >= 1 && _lpalloc <= 100, "E72");
        require(_stakealloc >= 1 && _stakealloc <= 100, "E73");
        require(_stakealloc.add(_lpalloc) <= 100, "E74");

        lpalloc = _lpalloc;
        stakealloc = _stakealloc;
    }

    function updateStakeReward(uint256 _stakeReward) external onlyAuthorized {
        stakeReward = _stakeReward;
    }

    function updateStakedDiscount(uint256 _stakedDiscount) external onlyAuthorized {
        require(_stakedDiscount >= 0 && _stakedDiscount <= 50, "E81");
        stakedDiscount = _stakedDiscount;
    }

    function updateSplits(uint256 _lottoSplit, uint256 _lootboxSplit) external onlyAuthorized {
        require(_lottoSplit >=0 && _lottoSplit <= 100, "E82");
        require(_lottoSplit.add(_lootboxSplit) == 100, "E83");

        lottoSplit = _lottoSplit;
        lootboxSplit = _lootboxSplit;

    }

    function getUserStaked(address _holder) external view returns (bool) {
        return userStaked[0][_holder] || userStaked[1][_holder];
    }

    function getPackTotalPrice(address _holder, uint _packid) public view returns (uint) {

        uint256 packTotalPrice = ITeazePacks(directory.getPacks()).getUserPackPrice(_holder, _packid);
        if(userStaked[0][_holder] || userStaked[1][_holder]) {
            return packTotalPrice.sub(packTotalPrice.mul(stakedDiscount).div(100));
        } else {
            return packTotalPrice;
        }
    }

    function enableSimpCardBonus(bool _status) external onlyAuthorized {
        simpCardBonusEnabled = _status;
    }

    function isSimpCardHolder(address _holder) public view returns (bool) {
        if (IERC721(simpCardContract).balanceOf(_holder) > 0) {return true;} else {return false;}
    }
    
    function getSimpCardPackPrice(uint _packid, address _holder) public view returns (uint) {
        (,,uint256 packSimpBuxPrice,,,) = ITeazePacks(directory.getPacks()).getPackInfo(_packid);
        
        if (simpCardBonusEnabled) {
                if (isSimpCardHolder(_holder)) {
                    return packSimpBuxPrice.sub(packSimpBuxPrice.mul(simpCardRedeemDiscount.add(100)).div(100));
                } else {
                    return packSimpBuxPrice;
                }
        } else {
           return packSimpBuxPrice;
        }
    }

    function increaseMintToken(address _holder) external {
        require(msg.sender == address(directory.getLotto()) || msg.sender == address(directory.getNFT()) || authorized[_msgSender()], "E84");
        mintToken[_holder] = mintToken[_holder] + 1;
    }

    function decreaseMintToken(address _holder) external {
        require(msg.sender == address(directory.getLotto()) || msg.sender == address(directory.getNFT()) || authorized[_msgSender()], "E84");
        if(mintToken[_holder] > 0) {mintToken[_holder] = mintToken[_holder] - 1;}
    }

    function getMintTokens(address _holder) public view returns (uint) {
        return mintToken[_holder];
    }

    function changeSimpCardContract(address _contract) external onlyAuthorized {
        simpCardContract = _contract;
    }

    function changeDirectory(address _directory) external onlyOwner {
        directory = IDirectory(_directory);
    }
    
}
