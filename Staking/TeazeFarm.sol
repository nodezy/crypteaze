// SPDX-License-Identifier: MIT

// Teaze.Finance Staking Contract Version 1.0
// Stake your $teaze or LP tokens to receive Teazecash rewards (XXXCASH)

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./tzcash.sol";

interface ITeazeNFT {
  function mint(address to, uint256 id) external;
  function getCreatorAddress(uint256 _nftid) external view returns (address);
  function getCreatorPrice(uint256 _nftid) external view returns (uint256);
  function getCreatorSplit(uint256 _nftid) external view returns (uint256);
  function getCreatorMintLimit(uint256 _nftid) external view returns (uint256);
  function getCreatorRedeemable(uint256 _nftid) external view returns (bool);
  function getCreatorPurchasable(uint256 _nftid) external view returns (bool);
  function getCreatorExists(uint256 _nftid) external view returns (bool);
  function mintedCountbyID(uint256 _id) external view returns (uint256);
}

// Allows another user(s) to change contract variables
contract Authorizable is Ownable {

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

contract TeazeFarm is Ownable, Authorizable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of TEAZECASH tokens
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
        uint256 allocPoint; // How many allocation points assigned to this pool. TEAZECASH tokens to distribute per block.
        uint256 lastRewardBlock; // Last block number that TEAZECASH tokens distribution occurs.
        uint256 accTeazePerShare; // Accumulated TEAZECASH tokens per share, times 1e12. See below.
        uint256 runningTotal; // Total accumulation of tokens (not including reflection, pertains to pool 1 ($Teaze))
    }

    TeazeCash public immutable teazecash; // The TEAZECASH ERC-20 Token.
    uint256 private teazePerBlock; // TEAZECASH tokens distributed per block. Use getTeazePerBlock() to get the updated reward.

    PoolInfo[] public poolInfo; // Info of each pool.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo; // Info of each user that stakes LP tokens.
    
    uint256 public totalAllocPoint; // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public startBlock; // The block number when TEAZECASH token mining starts.

    uint256 public blockRewardUpdateCycle = 1 days; // The cycle in which the teazePerBlock gets updated.
    uint256 public blockRewardLastUpdateTime = block.timestamp; // The timestamp when the block teazePerBlock was last updated.
    uint256 public blocksPerDay = 5000; // The estimated number of mined blocks per day, lowered so rewards are halved to start.
    uint256 public blockRewardPercentage = 10; // The percentage used for teazePerBlock calculation.
    uint256 public unstakeTime = 86400; // Time in seconds to wait for withdrawal default (86400).
    uint256 public poolReward = 1000000000000000000000; //starting basis for poolReward (default 1k).
    uint256 public conversionRate = 100000; //conversion rate of TEAZECASH => $teaze (default 100k).
    bool public enableRewardWithdraw = false; //whether TEAZECASH is withdrawable from this contract (default false).
    uint256 public minTeazeStake = 21000000000000000000000000; //min stake amount (default 21 million Teaze).
    uint256 public maxTeazeStake = 2100000000000000000000000000; //max stake amount (default 2.1 billion Teaze).
    uint256 public minLPStake = 1000000000000000000000; //min lp stake amount (default 1000 LP tokens).
    uint256 public maxLPStake = 10000000000000000000000; //max lp stake amount (default 10,000 LP tokens).
    uint256 public promoAmount = 200000000000000000000; //amount of TEAZECASH to give to new stakers (default 200 TEAZECASH).
    bool public promoActive = true; //whether the promotional amount of TEAZECASH is given out to new stakers (default is True).
    uint256 public rewardSegment = poolReward.mul(100).div(200); //reward segment for dynamic staking.
    uint256 public ratio; //ratio of pool0 to pool1 for dynamic staking.
    uint256 public lpalloc = 65; //starting pool allocation for LP side.
    uint256 public stakealloc = 35; //starting pool allocation for Teaze side.
    uint256 public allocMultiplier = 5; //ratio * allocMultiplier to balance out the pools.
    bool public dynamicStakingActive = true; //whether the staking pool will auto-balance rewards or not.

    mapping(address => bool) public addedLpTokens; // Used for preventing LP tokens from being added twice in add().
    mapping(uint256 => mapping(address => uint256)) public unstakeTimer; // Used to track time since unstake requested.
    mapping(address => uint256) private userBalance; // Balance of TeazeCash for each user that survives staking/unstaking/redeeming.
    mapping(address => bool) private promoWallet; // Whether the wallet has received promotional TEAZECASH.
    mapping(uint256 => uint256) public totalEarnedCreator; // Total amount of $teaze token spent to creator on a particular NFT.
    mapping(uint256 => uint256) public totalEarnedPool; // Total amount of $teaze token spent to pool on a particular NFT.
    mapping(uint256 => uint256) public totalEarnedBurn; // Total amount of $teaze token spent to burn on a particular NFT.
    mapping(uint256 =>mapping(address => bool)) public userStaked; // Denotes whether the user is currently staked or not.
    
    address public NFTAddress; //NFT contract address
    address public TeazeCashAddress; //TEAZECASH contract address

    IERC20 teazetoken = IERC20(0x4faB740779C73aA3945a5CF6025bF1b0e7F6349C); //teaze token

    event Unstake(address indexed user, uint256 indexed pid);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event WithdrawRewardsOnly(address indexed user, uint256 amount);

    constructor(
        TeazeCash _teaze,
        uint256 _startBlock
    ) {
        require(address(_teaze) != address(0), "TEAZECASH address is invalid");
        //require(_startBlock >= block.number, "startBlock is before current block");

        teazecash = _teaze;
        TeazeCashAddress = address(_teaze);
        startBlock = _startBlock;
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

    // Update the given pool's TEAZECASH token allocation point. Can only be called by the owner.
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

    // Update the given pool's TEAZECASH token allocation point when pool.
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

    // View function to see pending TEAZECASH tokens on frontend.
    function pendingRewards(uint256 _pid, address _user) public view returns (uint256) {
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

        // no minting is required, the contract should have TEAZECASH token balance pre-allocated
        // accumulated TEAZECASH per share is stored multiplied by 10^12 to allow small 'fractional' values
        pool.accTeazePerShare = pool.accTeazePerShare.add(teazeReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    function updatePoolReward(uint256 _amount) public onlyAuthorized {
        poolReward = _amount;
    }

    // Deposit LP tokens/$Teaze to TeazeFarming for TEAZECASH token allocation.
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_msgSender()];

        updatePool(_pid);

        if (_amount > 0) {

            if(user.amount > 0) { //if user has already deposited, secure rewards before reconfiguring rewardDebt
                uint256 tempRewards = pendingRewards(_pid, _msgSender());
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
                userBalance[_msgSender()] = promoAmount; //give 200 promo TEAZECASH
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

                    uint256 tempRewards = pendingRewards(_pid, _msgSender());
                    userBalance[_msgSender()] = userBalance[_msgSender()].add(tempRewards);

                    pool.runningTotal = pool.runningTotal.sub(_amount);
                    pool.lpToken.safeTransfer(address(_msgSender()), _amount);
                    user.amount = user.amount.sub(_amount);
                    emit Withdraw(_msgSender(), _pid, _amount);
                    
                } 
                if (totalRewards > 0) { //include reflection

                    uint256 tempRewards = pendingRewards(_pid, _msgSender());
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


                uint256 tempRewards = pendingRewards(_pid, _msgSender());
                
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

    // Safe TEAZECASH token transfer function, just in case if
    // rounding error causes pool to not have enough TEAZECASH tokens
    function safeTokenTransfer(address _to, uint256 _amount) internal {
        uint256 balance = teazecash.balanceOf(address(this));
        uint256 amount = _amount > balance ? balance : _amount;
        teazecash.transfer(_to, amount);
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
    function getTotalPendingRewards(address _user) public view returns (uint256) { 
        uint256 value1 = pendingRewards(0, _user);
        uint256 value2 = pendingRewards(1, _user);

        return value1.add(value2);
    }

    //gets the total amount of rewards secured (not pending)
    function getAccruedRewards(address _user) external view returns (uint256) { 
        return userBalance[_user];
    }

    //gets the total of pending + secured rewards
    function getTotalRewards(address _user) external view returns (uint256) { 
        uint256 value1 = getTotalPendingRewards(_user);
        uint256 value2 = userBalance[_user];

        return value1.add(value2);
    }

    //moves all pending rewards into the accrued array
    function redeemTotalRewards(address _user) internal { 

        uint256 pool0 = 0;

        PoolInfo storage pool = poolInfo[pool0];
        UserInfo storage user = userInfo[pool0][_user];

        updatePool(pool0);
        
        uint256 value0 = pendingRewards(pool0, _user);
        
        userBalance[_user] = userBalance[_user].add(value0);

        user.rewardDebt = user.amount.mul(pool.accTeazePerShare).div(1e12); 

        uint256 pool1 = 1; 
        
        pool = poolInfo[pool1];
        user = userInfo[pool1][_user];

        updatePool(pool1);

        uint256 value1 = pendingRewards(pool1, _user);
        
        userBalance[_user] = userBalance[_user].add(value1);

        user.rewardDebt = user.amount.mul(pool.accTeazePerShare).div(1e12); 
    }

    //whether to allow the TeazeCash token to actually be withdrawn, of just leave it virtual (default)
    function enableRewardWithdrawals(bool _status) public onlyAuthorized {
        enableRewardWithdraw = _status;
    }

    //view state of reward withdrawals (true/false)
    function rewardWithdrawalStatus() external view returns (bool) {
        return enableRewardWithdraw;
    }

    //withdraw TeazeCash
    function withdrawRewardsOnly() public nonReentrant {

        require(enableRewardWithdraw, "TEAZECASH withdrawals are not enabled");

        IERC20 rewardtoken = IERC20(TeazeCashAddress); //TEAZECASH

        redeemTotalRewards(_msgSender());

        uint256 pending = userBalance[_msgSender()];
        if (pending > 0) {
            require(rewardtoken.balanceOf(address(this)) > pending, "TEAZECASH token balance of this contract is insufficient");
            userBalance[_msgSender()] = 0;
            safeTokenTransfer(_msgSender(), pending);
        }
        
        emit WithdrawRewardsOnly(_msgSender(), pending);
    }

    // Set NFT contract address
     function setNFTAddress(address _address) external onlyAuthorized {
        NFTAddress = _address;
    }

    // Set TEAZECASH contract address
     function setTeazeCashAddress(address _address) external onlyAuthorized {
        TeazeCashAddress = _address;
    }

    //redeem the NFT with TEAZECASH only
    function redeem(uint256 _nftid) public nonReentrant {
    
        uint256 creatorPrice = ITeazeNFT(NFTAddress).getCreatorPrice(_nftid);
        bool creatorRedeemable = ITeazeNFT(NFTAddress).getCreatorRedeemable(_nftid);
        uint256 creatorMinted = ITeazeNFT(NFTAddress).mintedCountbyID(_nftid);
        uint256 creatorMintLimit = ITeazeNFT(NFTAddress).getCreatorMintLimit(_nftid);
    
        require(creatorRedeemable, "This NFT is not redeemable with TeazeCash");
        require(creatorMinted < creatorMintLimit, "This NFT has reached its mint limit");

        uint256 price = creatorPrice;

        require(price > 0, "NFT not found");

        redeemTotalRewards(_msgSender());

        if (userBalance[_msgSender()] < price) {
            
            IERC20 rewardtoken = IERC20(TeazeCashAddress); //TEAZECASH
            require(rewardtoken.balanceOf(_msgSender()) >= price, "You do not have the required tokens for purchase"); 
            ITeazeNFT(NFTAddress).mint(_msgSender(), _nftid);
            IERC20(rewardtoken).transferFrom(_msgSender(), address(this), price);

        } else {

            require(userBalance[_msgSender()] >= price, "Not enough TeazeCash to redeem");
            ITeazeNFT(NFTAddress).mint(_msgSender(), _nftid);
            userBalance[_msgSender()] = userBalance[_msgSender()].sub(price);

        }

    }

    //set the conversion rate between TEAZECASH and the $teaze token
    function setConverstionRate(uint256 _rate) public onlyAuthorized {
        conversionRate = _rate;
    }

    // users can also purchase the NFT with $teaze token and the proceeds can be split between the NFT influencer/artist and the staking pool
    function purchase(uint256 _nftid) public nonReentrant {
        
        address creatorAddress = ITeazeNFT(NFTAddress).getCreatorAddress(_nftid);
        uint256 creatorPrice = ITeazeNFT(NFTAddress).getCreatorPrice(_nftid);
        uint256 creatorSplit = ITeazeNFT(NFTAddress).getCreatorSplit(_nftid);
        uint256 creatorMinted = ITeazeNFT(NFTAddress).mintedCountbyID(_nftid);
        uint256 creatorMintLimit = ITeazeNFT(NFTAddress).getCreatorMintLimit(_nftid);
        bool creatorPurchasable = ITeazeNFT(NFTAddress).getCreatorPurchasable(_nftid);
        bool creatorExists = ITeazeNFT(NFTAddress).getCreatorExists(_nftid);

        uint256 price = creatorPrice;
        price = price.mul(conversionRate);

        require(creatorPurchasable, "This NFT is not purchasable with Teaze tokens");
        require(creatorMinted < creatorMintLimit, "This NFT has reached its mint limit");
        require(teazetoken.balanceOf(_msgSender()) >= price, "You do not have the required tokens for purchase"); 
        ITeazeNFT(NFTAddress).mint(_msgSender(), _nftid);

        distributeTeaze(_nftid, creatorAddress, price, creatorSplit, creatorExists);

        
    }

    function distributeTeaze(uint256 _nftid, address _creator, uint256 _price, uint256 _creatorSplit, bool _creatorExists) internal {
        if (_creatorExists) { 
            uint256 creatorShare;
            uint256 remainingShare;
            uint256 burnShare;
            uint256 poolShare;
            creatorShare = _price.mul(_creatorSplit).div(100);
            remainingShare = _price.sub(creatorShare);           

            IERC20(teazetoken).transferFrom(_msgSender(), address(this), _price);

            if (creatorShare > 0) {

                totalEarnedCreator[_nftid] = totalEarnedCreator[_nftid].add(creatorShare);
                IERC20(teazetoken).safeTransfer(address(_creator), creatorShare);                
                
            }

            if (remainingShare > 0) {
                burnShare = remainingShare.mul(50).div(100);
                poolShare = remainingShare.mul(50).div(100);

                totalEarnedPool[_nftid] = totalEarnedPool[_nftid].add(poolShare);
                IERC20(teazetoken).safeTransfer(address(0x000000000000000000000000000000000000dEaD), burnShare);
                totalEarnedBurn[_nftid] = totalEarnedBurn[_nftid].add(burnShare);
            }

        } else {
            IERC20(teazetoken).transferFrom(_msgSender(), address(this), _price.mul(50).div(100));
            totalEarnedPool[_nftid] = totalEarnedPool[_nftid].add(_price.mul(50).div(100));

            IERC20(teazetoken).transferFrom(_msgSender(), address(0x000000000000000000000000000000000000dEaD), _price.mul(50).div(100));
            totalEarnedBurn[_nftid] = totalEarnedBurn[_nftid].add(_price.mul(50).div(100));
        }
    }

    // We can give the artists/influencers a TeazeCash balance so they can redeem their own NFTs
    function setTeazeCashBalance(address _address, uint256 _amount) public onlyAuthorized {
        userBalance[_address] = _amount;
    }

    function reduceTeazeCashBalance(address _address, uint256 _amount) public onlyAuthorized {
        userBalance[_address] = userBalance[_address].sub(_amount);
    }

    function increaseTeazeCashBalance(address _address, uint256 _amount) public onlyAuthorized {
        userBalance[_address] = userBalance[_address].add(_amount);
    }

    // Get rate of TeazeCash/$Teaze conversion
    function getConversionRate() external view returns (uint256) {
        return conversionRate;
    }

    // Get price of NFT in $teaze based on TeazeCash _price
    function getConversionPrice(uint256 _price) external view returns (uint256) {
        uint256 newprice = _price.mul(conversionRate);
        return newprice;
    }

    // Get price of NFT in $teaze based on NFT
    function getConversionNFTPrice(uint256 _nftid) external view returns (uint256) {
        uint256 nftprice = ITeazeNFT(NFTAddress).getCreatorPrice(_nftid);
        uint256 newprice = nftprice.mul(conversionRate);
        return newprice;
    }

    // Get the holder rewards of users staked $teaze if they were to withdraw
    function getHolderRewards(address _address) external view returns (uint256) {
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
            redeemTotalRewards(_msgSender());
        }       
    }

    // Sets true/false for the TEAZECASH promo for new stakers
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


    
}