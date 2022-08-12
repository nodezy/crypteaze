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

// Allows another user(s) to change contract variables
contract Authorized is Ownable {

    mapping(address => bool) public authorized;

    modifier onlyAuthorized() {
        require(authorized[_msgSender()] || owner() == address(_msgSender()), "Sender is not authorized");
        _;
    }

    function addAuthorized(address _toAdd) onlyOwner public {
        require(_toAdd != address(0), "Address is the zero address");
        authorized[_toAdd] = true;
    }

    function removeAuthorized(address _toRemove) onlyOwner public {
        require(_toRemove != address(0), "Address is the zero address");
        require(_toRemove != address(_msgSender()), "Sender cannot remove themself");
        authorized[_toRemove] = false;
    }

}

contract TeazeFarm is Ownable, Authorized, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
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
    
    uint256 public totalAllocPoint; // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public startBlock; // The block number when SimpBux token mining starts.

    uint256 public blockRewardUpdateCycle = 1 days; // The cycle in which the teazePerBlock gets updated.
    uint256 public blockRewardLastUpdateTime = block.timestamp; // The timestamp when the block teazePerBlock was last updated.
    uint256 public blocksPerDay = 2500; // The estimated number of mined blocks per day, lowered so rewards are halved to start.
    uint256 public blockRewardPercentage = 10; // The percentage used for teazePerBlock calculation.
    uint256 public unstakeTime = 86400; // Time in seconds to wait for withdrawal default (86400).
    uint256 public poolReward = 1000000000000; //starting basis for poolReward (default 1k).
    bool public enableRewardWithdraw = false; //whether SimpBux is withdrawable from this contract (default false).
    uint256 public minTeazeStake = 25000000000000000; //min stake amount (default 25 million Teaze).
    uint256 public maxTeazeStake = 2100000000000000000; //max stake amount (default 2.1 billion Teaze).
    uint256 public minLPStake = 250000000000000000; //min lp stake amount (default .25 LP tokens).
    uint256 public maxLPStake = 210000000000000000000; //max lp stake amount (default 210 LP tokens).
    uint256 public promoAmount = 20000000000; //amount of SimpBux to give to new stakers (default 20 SimpBux).
    uint256 public stakedDiscount = 30; //amount the price of a pack mint is discounted if the user is staked (default 30%). 
    uint256 public packPurchaseSplit = 50; //amount of split between stakepool and nft creation wallet/lootbox wallets. Higher value = higher buyback sent to stakepool (default 50%).
    uint256 public nftMarketingSplit = 50; //amount of split between nft creation wallet and lootbotx wallet (default 50%).
    uint256 public lootboxSplit = 50; //amount of split between nft creation wallet and lootbotx wallet (default 50%).
    bool public promoActive = true; //whether the promotional amount of SimpBux is given out to new stakers (default is True).
    uint256 public rewardSegment = poolReward.mul(100).div(200); //reward segment for dynamic staking.
    uint256 public ratio; //ratio of pool0 to pool1 for dynamic staking.
    uint256 public lpalloc = 65; //starting pool allocation for LP side.
    uint256 public stakealloc = 35; //starting pool allocation for Teaze side.
    uint256 public allocMultiplier = 5; //ratio * allocMultiplier to balance out the pools.
    bool public dynamicStakingActive = true; //whether the staking pool will auto-balance rewards or not.

    mapping(address => bool) public addedLpTokens; // Used for preventing LP tokens from being added twice in add().
    mapping(uint256 => mapping(address => uint256)) public unstakeTimer; // Used to track time since unstake requested.
    mapping(address => uint256) private userBalance; // Balance of SimpBux for each user that survives staking/unstaking/redeeming.
    mapping(address => bool) private promoWallet; // Whether the wallet has received promotional SimpBux.
    mapping(address => bool) private mintToken; // Whether the wallet has received a mint token from the lottery.
    uint256 public totalEarnedLoot; //Total amount of BNB sent for lootbox creation.
    uint256 public totalEarnedLotto; //Total amount of BNB used to buy token before being sent to stakepool.
    uint256 public totalEarnedNFT; // Total amount of BNB NFT creation wallet to fund new NFTs.
    mapping(uint256 =>mapping(address => bool)) public userStaked; // Denotes whether the user is currently staked or not.
    

    address public SimpBuxAddress; //SimpBux contract address
    address public NFTmarketing = 0xbbd72e76cC3e09227e5Ca6B5bC4355d62061C9e4; //NFT/Marketing address
    address public lootboxAddress; //lootbox address
    address public packsContract; //SimpPacks
    address public simpCardContract;
    bool simpCardBonusEnabled = false;
    uint simpCardRedeemDiscount = 10;
    
    address public teazelotto; //teaze lotto address
    address public nftContract;
    address public teazetoken; //teaze token
    IERC20 iteazetoken; 

    uint256 marketBuyGas = 450000;

    event Unstake(address indexed user, uint256 indexed pid);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event WithdrawRewardsOnly(address indexed user, uint256 amount);

    constructor(
        SimpBux _simpbux,
        uint256 _startBlock,
        address _teazetoken
    ) {
        require(address(_simpbux) != address(0), "SimpBux address is invalid");
        //require(_startBlock >= block.number, "startBlock is before current block");

        simpbux = _simpbux;
        SimpBuxAddress = address(_simpbux);
        startBlock = _startBlock;
        teazetoken = _teazetoken;
        iteazetoken = IERC20(teazetoken); 

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
        require(address(_lpToken) != address(0), "LP token is invalid");
        require(!addedLpTokens[address(_lpToken)], "LP token is already added");

        require(_allocPoint >= 1 && _allocPoint <= 100, "_allocPoint is outside of range 1-100");

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
        require(_allocPoint >= 1 && _allocPoint <= 100, "_allocPoint is outside of range 1-100");

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
        require(_allocPoint >= 1 && _allocPoint <= 100, "_allocPoint is outside of range 1-100");

        if (_withUpdate) {
            updatePool(_pid);
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // View function to see pending SimpBux tokens on frontend.
    function pendingSBXRewards(uint256 _pid, address _user) public view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accTeazePerShare = pool.accTeazePerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = block.number.sub(pool.lastRewardBlock);
            (uint256 blockReward, ) = getTeazePerBlock();
            uint256 teazeReward = multiplier.mul(blockReward).mul(pool.allocPoint).div(totalAllocPoint);
            accTeazePerShare = accTeazePerShare.add(teazeReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accTeazePerShare).div(1e12).sub(user.rewardDebt);
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

        uint256 lpSupply = pool.runningTotal; 
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
                require(_amount >= minTeazeStake, "You cannot stake less than the minimum required $Teaze");
                }
                require(_amount.add(user.amount) <= maxTeazeStake, "You cannot stake more than the maximum $Teaze");
                pool.runningTotal = pool.runningTotal.add(_amount);
                user.amount = user.amount.add(_amount);  
                pool.lpToken.safeTransferFrom(address(_msgSender()), address(this), _amount);

                
            } else { //LP tokens
                if(user.amount == 0) { //we only want the minimum to apply on first deposit, not subsequent ones
                require(_amount >= minLPStake, "You cannot stake less than the minimum LP Tokens");
                }
                require(_amount.add(user.amount) <= maxLPStake, "You cannot stake more than the maximum LP Tokens");
                pool.runningTotal = pool.runningTotal.add(_amount);
                user.amount = user.amount.add(_amount);
                pool.lpToken.safeTransferFrom(address(_msgSender()), address(this), _amount);
            }
            
        
            unstakeTimer[_pid][_msgSender()] = 9999999999;
            userStaked[_pid][_msgSender()] = true;

            if (!promoWallet[_msgSender()] && promoActive) {
                userBalance[_msgSender()] = promoAmount; //give 200 promo SimpBux
                promoWallet[_msgSender()] = true;
            }

            if (dynamicStakingActive) {
                updateVariablePoolReward();
            }
            
            user.rewardDebt = user.amount.mul(pool.accTeazePerShare).div(1e12);
            emit Deposit(_msgSender(), _pid, _amount);

        }
    }

    function setUnstakeTime(uint256 _time) external onlyAuthorized {

        require(_time >= 0 || _time <= 172800, "Time should be between 0 and 2 days (in seconds)");
        unstakeTime = _time;
    }

    //Call unstake to start countdown
    function unstake(uint256 _pid) public {
        UserInfo storage user = userInfo[_pid][_msgSender()];
        require(user.amount > 0, "You have no amount to unstake");

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

    // Withdraw LP tokens from TeazeFarming
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_msgSender()];
        uint256 userAmount = user.amount;
        require(_amount > 0, "Withdrawal amount must be greater than zero");
        require(user.amount >= _amount, "Withdraw amount is greater than user amount");
        require(block.timestamp > unstakeTimer[_pid][_msgSender()], "Unstaking wait period has not expired");

        updatePool(_pid);

        if (_amount > 0) {

            if (_pid != 0) { //$Teaze tokens
                
                uint256 lpSupply = pool.lpToken.balanceOf(address(this)); //get total amount of tokens
                uint256 totalRewards = lpSupply.sub(pool.runningTotal); //get difference between contract address amount and ledger amount
                if (totalRewards == 0) { //no rewards, just return 100% to the user

                    uint256 tempRewards = pendingSBXRewards(_pid, _msgSender());
                    userBalance[_msgSender()] = userBalance[_msgSender()].add(tempRewards);

                    pool.runningTotal = pool.runningTotal.sub(_amount);
                    pool.lpToken.safeTransfer(address(_msgSender()), _amount);
                    user.amount = user.amount.sub(_amount);
                    emit Withdraw(_msgSender(), _pid, _amount);
                    
                } 
                if (totalRewards > 0) { //include reflection

                    uint256 tempRewards = pendingSBXRewards(_pid, _msgSender());
                    userBalance[_msgSender()] = userBalance[_msgSender()].add(tempRewards);

                    uint256 percentRewards = _amount.mul(100).div(pool.runningTotal); //get % of share out of 100
                    uint256 reflectAmount = percentRewards.mul(totalRewards).div(100); //get % of reflect amount

                    pool.runningTotal = pool.runningTotal.sub(_amount);
                    user.amount = user.amount.sub(_amount);
                    _amount = _amount.mul(99).div(100).add(reflectAmount);
                    pool.lpToken.safeTransfer(address(_msgSender()), _amount);
                    emit Withdraw(_msgSender(), _pid, _amount);
                }               

            } else {


                uint256 tempRewards = pendingSBXRewards(_pid, _msgSender());
                
                userBalance[_msgSender()] = userBalance[_msgSender()].add(tempRewards);
                user.amount = user.amount.sub(_amount);
                pool.runningTotal = pool.runningTotal.sub(_amount);
                pool.lpToken.safeTransfer(address(_msgSender()), _amount);
                emit Withdraw(_msgSender(), _pid, _amount);
            }
            

            if (dynamicStakingActive) {
                    updateVariablePoolReward();
            }

            if (userAmount == _amount) { //user is retrieving entire balance, set rewardDebt to zero
                user.rewardDebt = 0;
            } else {
                user.rewardDebt = user.amount.mul(pool.accTeazePerShare).div(1e12); 
            }

        }
        
                        
    }

    // Safe simpbux token transfer function, just in case if
    // rounding error causes pool to not have enough simpbux tokens
    function safeTokenTransfer(address _to, uint256 _amount) internal {
        uint256 balance = simpbux.balanceOf(address(this));
        uint256 amount = _amount > balance ? balance : _amount;
        simpbux.transfer(_to, amount);
    }

    function setBlockRewardUpdateCycle(uint256 _blockRewardUpdateCycle) external onlyAuthorized {
        require(_blockRewardUpdateCycle > 0, "Value is zero");
        blockRewardUpdateCycle = _blockRewardUpdateCycle;
    }

    // Just in case an adjustment is needed since mined blocks per day
    // changes constantly depending on the network
    function setBlocksPerDay(uint256 _blocksPerDay) external onlyAuthorized {
        require(_blocksPerDay >= 1 && _blocksPerDay <= 14000, "Value is outside of range 1-14000");
        blocksPerDay = _blocksPerDay;
    }

    function setBlockRewardPercentage(uint256 _blockRewardPercentage) external onlyAuthorized {
        require(_blockRewardPercentage >= 1 && _blockRewardPercentage <= 5, "Value is outside of range 1-5");
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
        require(_tokenAddr != address(0xcDC477f2ccFf2d8883067c9F23cf489F2B994d00), "Cannot transfer out LP token");
        require(_tokenAddr != address(0x4faB740779C73aA3945a5CF6025bF1b0e7F6349C), "Cannot transfer out $Teaze token");
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

        require(enableRewardWithdraw, "SimpBux withdrawals are not enabled");

        IERC20 rewardtoken = IERC20(SimpBuxAddress); //SimpBux

        redeemTotalSBXRewards(_msgSender());

        uint256 pending = userBalance[_msgSender()];
        if (pending > 0) {
            require(rewardtoken.balanceOf(address(this)) > pending, "SimpBux token balance of this contract is insufficient");
            userBalance[_msgSender()] = 0;
            safeTokenTransfer(_msgSender(), pending);
        }
        
        emit WithdrawRewardsOnly(_msgSender(), pending);
    }

    // Set teazelotto contract address
     function setNFTContract(address _address) external onlyAuthorized {
        nftContract = _address;
    }

    // Set teazelotto contract address
     function setLottoContract(address _address) external onlyAuthorized {
        teazelotto = _address;
    }

    // Set packs contract address
     function setPacksContract(address _address) external onlyAuthorized {
        packsContract = _address;
    }

    // Set SimpBux contract address
     function setSimpBuxAddress(address _address) external onlyAuthorized {
        SimpBuxAddress = _address;
    }

    // Set lootbox address
     function setlootboxAddress(address _address) external onlyAuthorized {
        lootboxAddress = _address;
    }

    // Set NFT contract address
     function setNFTMarketingAddress(address _address) external onlyAuthorized {
        NFTmarketing = _address;
    }

    //redeem the NFT with SimpBux only
    function redeem(uint256 _packid) public nonReentrant {

        require(packsContract != address(0), "Packs address invalid");
        require(ITeazePacks(packsContract).getPackTimelimitFarm(_packid), "Pack has expired");

        uint256 packMinted = ITeazePacks(packsContract).mintedCountbyID(_packid);
   
        (,,,uint256 packMintLimit,bool packRedeemable,) = ITeazePacks(packsContract).getPackInfo(_packid);
    
        require(packRedeemable, "This NFT is not redeemable with SimpBux");
        require(packMinted < packMintLimit, "This NFT has reached its mint limit");

        uint256 price = getSimpCardPackPrice(_packid, _msgSender());

        require(price > 0, "NFT not found");

        redeemTotalSBXRewards(_msgSender());

        if (userBalance[_msgSender()] < price) {
            
            IERC20 rewardtoken = IERC20(SimpBuxAddress); //SimpBux
            require(rewardtoken.balanceOf(_msgSender()) >= price, "You do not have the required tokens for purchase"); 
            ITeazePacks(packsContract).premint(_msgSender(), _packid);
            IERC20(rewardtoken).transferFrom(_msgSender(), address(this), price);

        } else {

            require(userBalance[_msgSender()] >= price, "Not enough SimpBux to redeem");
            ITeazePacks(packsContract).premint(_msgSender(), _packid);
            userBalance[_msgSender()] = userBalance[_msgSender()].sub(price);

        }

    }

    // users can also purchase the NFT with $teaze token and the proceeds can be split between nft creation address, lootbox address, and the staking pool
    function purchase(uint256 _packid) public payable nonReentrant {

        require(packsContract != address(0), "Packs address invalid");
        require(ITeazePacks(packsContract).getPackTimelimitFarm(_packid), "Pack has expired");


        (,,,uint256 packMintLimit,, bool packPurchasable) = ITeazePacks(packsContract).getPackInfo(_packid);
        
        uint256 packMinted = ITeazePacks(packsContract).getPackTotalMints(_packid);

        uint256 price = getPackTotalPrice(_msgSender(), _packid);        

        require(packPurchasable, "This NFT is not purchasable with BNB");
        require(packMinted < packMintLimit, "This NFT Pack has reached its mint limit");
        require(msg.value == price, "BNB is insufficient for purchase");

        uint256 netamount = msg.value.mul(packPurchaseSplit).div(100);
        uint256 netremainder = msg.value.sub(netamount);
            
        ITeazePacks(packsContract).premint(_msgSender(), _packid);
        ITeazePacks(packsContract).packPurchased(_msgSender(),_packid);

        payable(teazelotto).transfer(netamount);
        totalEarnedLotto = totalEarnedLotto + netamount;
        
        payable(NFTmarketing).transfer(netremainder.mul(nftMarketingSplit).div(100));
        totalEarnedNFT = totalEarnedNFT + netremainder.mul(nftMarketingSplit).div(100);

        payable(lootboxAddress).transfer(netremainder.mul(lootboxSplit).div(100));
        totalEarnedLoot = totalEarnedLoot + netremainder.mul(lootboxSplit).div(100);
        
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
        require(msg.sender == address(teazelotto) || msg.sender == address(packsContract), "Function may only be called by the approved contract");
        userBalance[_address] = userBalance[_address].add(_amount);
    }


    // Get the holder rewards of users staked $teaze if they were to withdraw
    function getTeazeHolderRewards(address _address) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[1];
        UserInfo storage user = userInfo[1][_address];

        uint256 _amount = user.amount;
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

    // Sets min/max staking amounts for Teaze token
    function setTeazeStakingMinMax(uint256 _min, uint256 _max) external onlyAuthorized {

        require(_min < _max, "The maximum staking amount is less than the minimum");
        require(_min > 0, "The minimum amount cannot be zero");

        minTeazeStake = _min;
        maxTeazeStake = _max;
    }

    // Sets min/max amounts for LP staking
    function setLPStakingMinMax(uint256 _min, uint256 _max) external onlyAuthorized {

        require(_min < _max, "The maximum staking amount is less than the minimum");
        require(_min > 0, "The minimum amount cannot be zero");

        minLPStake = _min;
        maxLPStake = _max;
    }

    // Lets user move their pending rewards to accrued/escrow balance
    function moveRewardsToEscrow(address _address) external {

        require(_address == _msgSender() || authorized[_msgSender()], "Sender is not wallet owner or authorized");

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

    function setDynamicStakingEnabled(bool _status) external onlyAuthorized {
        dynamicStakingActive = _status;
    }

    // Sets the allocation multiplier
    function setAllocMultiplier(uint256 _newAllocMul) external onlyAuthorized {

        require(_newAllocMul >= 1 && _newAllocMul <= 100, "_allocPoint is outside of range 1-100");

        allocMultiplier = _newAllocMul;
    }

    function setAllocations(uint256 _lpalloc, uint256 _stakealloc) external onlyAuthorized {

        require(_lpalloc >= 1 && _lpalloc <= 100, "lpalloc is outside of range 1-100");
        require(_stakealloc >= 1 && _stakealloc <= 100, "stakealloc is outside of range 1-100");
        require(_stakealloc.add(_lpalloc) == 100, "amounts should add up to 100");

        lpalloc = _lpalloc;
        stakealloc = _stakealloc;
    }

    // Changes poolReward dynamically based on how many Teaze tokens + LP Tokens are staked to keep rewards consistent
    function updateVariablePoolReward() private {

        PoolInfo storage pool0 = poolInfo[0];
        uint256 runningTotal0 = pool0.runningTotal;
        uint256 lpratio;

        PoolInfo storage pool1 = poolInfo[1];
        uint256 runningTotal1 = pool1.runningTotal;
        uint256 stakeratio;

        uint256 multiplier;
        uint256 ratioMultiplier;
        uint256 newLPAlloc;
        uint256 newStakeAlloc;

        if (runningTotal0 >= maxLPStake) {
            lpratio = SafeMath.div(runningTotal0, maxLPStake, "lpratio >= maxLPStake divison error");
        } else {
            lpratio = SafeMath.div(maxLPStake, maxLPStake, "lpratio maxLPStake / maxLPStake division error");
        }

        if (runningTotal1 >= maxTeazeStake) {
             stakeratio = SafeMath.div(runningTotal1, maxTeazeStake, "stakeratio >= maxTeazeStake division error"); 
        } else {
            stakeratio = SafeMath.div(maxTeazeStake, maxTeazeStake, "stakeratio maxTeazeStake / maxTeazeStake division error");
        }   

        multiplier = SafeMath.add(lpratio, stakeratio);
        
        poolReward = SafeMath.mul(rewardSegment, multiplier);

        if (stakeratio == lpratio) { //ratio of pool rewards should remain the same (65 lp, 35 stake)
            adjustPools(0, lpalloc, true);
            adjustPools(1, stakealloc, true);
        }

        if (stakeratio > lpratio) {
            ratio = SafeMath.div(stakeratio, lpratio, "stakeratio > lpratio division error");
            
             ratioMultiplier = ratio.mul(allocMultiplier);

             if (ratioMultiplier < lpalloc) {
                newLPAlloc = lpalloc.sub(ratioMultiplier);
             } else {
                 newLPAlloc = 5;
             }

             newStakeAlloc = stakealloc.add(ratioMultiplier);

             if (newStakeAlloc > 95) {
                 newStakeAlloc = 95;
             }

             adjustPools(0, newLPAlloc, true);
             adjustPools(1, newStakeAlloc, true);

        }

        if (lpratio > stakeratio) {
            ratio = SafeMath.div(lpratio, stakeratio,  "lpratio > stakeratio division error");

            ratioMultiplier = ratio.mul(allocMultiplier);

            if (ratioMultiplier < stakealloc) {
                newStakeAlloc = stakealloc.sub(ratioMultiplier);
            } else {
                 newStakeAlloc = 5;
            }

             newLPAlloc = lpalloc.add(ratioMultiplier);

            if (newLPAlloc > 95) {
                 newLPAlloc = 95;
            }

             adjustPools(0, newLPAlloc, true);
             adjustPools(1, newStakeAlloc, true);
        }


    }

    function changeBuyGasLimit(uint256 _gasLimitAmount) external onlyAuthorized {
        marketBuyGas = _gasLimitAmount;
    }

    function updateStakedDiscount(uint256 _stakedDiscount) external onlyAuthorized {
        require(_stakedDiscount >= 0 && _stakedDiscount <= 50, "staker discount must be between 0 and 50 percent");
        stakedDiscount = _stakedDiscount;
    }

    function updateSplits(uint256 _packPurchaseSplit, uint256 _nftMarketingSplit, uint256 _lootboxSplit) external onlyAuthorized {
        require(_packPurchaseSplit >=0 && _packPurchaseSplit <= 100, "pack BNB split must be between 0 and 100 percent");
        require(_nftMarketingSplit.add(_lootboxSplit) == 100, "NFT creation and lootbox splits must add up to 100 percent");

        packPurchaseSplit = _packPurchaseSplit;
        nftMarketingSplit = _nftMarketingSplit;
        lootboxSplit = _lootboxSplit;

    }

    function getUserStaked(address _holder) external view returns (bool) {
        return userStaked[0][_holder] || userStaked[1][_holder];
    }

    function getPackTotalPrice(address _holder, uint _packid) public view returns (uint) {

        uint256 packTotalPrice = ITeazePacks(packsContract).getUserPackPrice(_holder, _packid);
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
        (,,uint256 packSimpBuxPrice,,,) = ITeazePacks(packsContract).getPackInfo(_packid);
        
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

    function setMintToken(bool _status, address _holder) external {
        require(msg.sender == address(teazelotto) || msg.sender == address(nftContract) || authorized[_msgSender()], "Function may only be called by the approved contract");
        mintToken[_holder] = _status;
    }

    function hasMintToken(address _holder) public view returns (bool) {
        return mintToken[_holder];
    }
    
}
