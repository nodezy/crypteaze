// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// Allows another user(s) to change contract variables
contract Authorized is Ownable {

    mapping(address => bool) public authorized;


    modifier onlyAuthorized() {
        require(authorized[_msgSender()] || owner() == address(_msgSender()), "Caller is not owner or authorized");
        _;
    }

    function addAuthorized(address _toAdd) onlyOwner public {
        require(_toAdd != address(0));
        authorized[_toAdd] = true;
        
    }

    function removeAuthorized(address _toRemove) onlyOwner public {
        require(_toRemove != address(0));
        require(_toRemove != address(_msgSender()));
        authorized[_toRemove] = false;
    }

}

interface IOracle {
    function getTeazeUSDPrice() external view returns (uint256, uint256, uint256);
    function getbnbusdequivalent(uint256 amount) external view returns (uint256);
}

interface ITeazeFarm {
    function getUserStaked(address _holder) external view returns (bool);
    function increaseSBXBalance(address _address, uint256 _amount) external;
    function getMintTokens(address _holder) external view returns (uint);
    function increaseMintToken(address _holder) external;
}

interface Inserter {
    function makeActive() external; 
    function getNonce() external view returns (uint256);
    function getRandMod(uint256 _extNonce, uint256 _modifier, uint256 _modulous) external view returns (uint256);
    function getRandLotto(uint256 _extNonce, uint256 _modifier) external view returns (uint256);
}

interface IDEXRouter {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

interface LastLotto {
    function userlotto(address _holder) external view returns (uint32,uint32,uint32,uint32,uint32,uint128,uint128);
    function globallotto(uint _struct) external view returns (uint32,uint32,uint32,uint128,uint128,uint128,uint128);
}

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint value) external returns (bool);
    function approve(address spender, uint value) external returns (bool);
    function balanceOf(address owner) external view returns (uint);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

interface Directory {
    function getDiscount1() external view returns (address);
    function getDiscount2() external view returns (address);
    function getDiscount3() external view returns (address);
    function getTeazeToken() external view returns (address);
    function getPair() external view returns (address);
    function getFarm() external view returns (address);
    function getInserter() external view returns (address);
}

contract TeazeLotto is Ownable, Authorized, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeMath for uint16;
    using SafeMath for uint8;
    using SafeERC20 for IERC20;

    struct globalLotteryData {
        uint32 globalSpins;
        uint32 globalWins;
        uint32 globalSBX;
        uint128 globalTeaze;
        uint128 globalBNBTeaze;
        uint128 globalJackpots;
        uint128 globalJackpotsBNB;
    }

    struct userLotteryData {
        uint32 lastSpinTime; 
        uint32 lastDailySpin; 
        uint32 totalSBX; 
        uint32 totalSpins; 
        uint32 totalWins; 
        uint128 totalJackpots; 
        uint128 totalJackpotsBNB; 
    }

    mapping(uint256 => globalLotteryData) public globallotto; 
    mapping(address => userLotteryData) public userlotto; 
    
    IOracle public oracle;
    IDEXRouter router;
    Directory public directory;

    address public simpCardContract;
    address lastLottery;
    address WETH;

    uint8 public feeReduction = 4; //amount we want overrideFee reduced for spin & trigger fees
    uint8 public overrideFee = 1;  //override fee in whole USD  
    uint8 public winningPercent = 50;
    uint8 public spinResultBonus = 10;
    uint8 public overage = 10; 
    uint8 public gasrefund = 3; 
    uint16 simpWheelBaseReward = 25;
    uint16 winningNumber; 
    uint16 public winningRoll = 499; //adjustable roll # so SBX win % can be 50/50 
    uint16 public spinFrequencyReduction = 3600;
    uint16 public mintbonuspercent = 975;
    uint16 public  discountbonuspercent = 950;
    uint24 marketBuyGas = 230000;  
    uint24 public spinFrequency = 18000;    //18000 for production
    uint32 public priceCheckInterval = 900;   //900 for production
    uint128 public jackpotLimit = 2 ether;
    uint128 public jackpotLimitDefault = 2 ether;
    uint128 public blockstart = uint128(block.timestamp);
    uint256 public LastPriceTime;
    uint256 private seed;
    uint256 private randNonce;
    
    bool public adminWinner = false; //to test winning jackpot roll, remove for production
    bool public simpCardBonusEnabled = false;
    bool public nftbonusenabled = false;
    bool public discountbonusenabled = false;
    bool public mintTokenWin = true; //remove for production
    bool public discountTokenWin = true; //remove for production
    
    event SpinResult(uint indexed roll, uint indexed userReward, bool indexed jackpotWinner, uint jackpotamount);
    event TeazeBuy(uint indexed amountBNB, uint indexed amountTeaze);
    event Jackpot(uint indexed amountBNB, uint indexed winningRoll, address indexed winner);
    event PriceHistory(uint indexed timestamp, uint indexed price);
    event DiscountTokenSent(bool indexed status);
    event MintTokenAdded(bool indexed status);

    constructor(address _directory, address _router, address _lastlottery, uint16 _seed) {
       directory = Directory(_directory);
       authorized[owner()] = true;
       randNonce = Inserter(directory.getInserter()).getNonce();
       Inserter(directory.getInserter()).makeActive();
       lastLottery = _lastlottery;
       seed = _seed;
       
       router = _router != address(0)
            ? IDEXRouter(_router)
            : IDEXRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E); //0xCc7aDc94F3D80127849D2b41b6439b7CF1eB4Ae0 pcs test router
        WETH = router.WETH();

        updateGlobalLotteryNumbers();
        updateGlobalJackpotData();
    }
    
    receive() external payable {}


    function SpinSimpWheel(bool _override) external payable nonReentrant {

        if(winningNumber == 0){
            winningNumber = uint16(Inserter(directory.getInserter()).getRandLotto(randNonce, seed));
        }

        globalLotteryData storage Lotto = globallotto[0];
        userLotteryData storage User = userlotto[_msgSender()];

        if(User.lastDailySpin == 0) {
            updateUserNumbers(_msgSender());
            updateUserJackpotData(_msgSender());
            User.lastSpinTime = 0;
        }
        
        randNonce++;

        Lotto.globalSpins++;

        User.totalSpins++;
                
        bool staked = ITeazeFarm(directory.getFarm()).getUserStaked(_msgSender());

       // require(staked, "User must be staked to spin the SimpWheel of Fortune");  //uncomment for production
    
        if(!_override) {
            if(User.lastSpinTime != 0) {
                require(block.timestamp.sub(User.lastSpinTime) >= spinFrequency, "Not eligible to spin yet");
            }
            require(msg.value >= returnFeeReduction(overrideFee,feeReduction).mul(99).div(100), "Please include the spin fee to spin the SimpWheel");
            
            if (simpCardBonusEnabled) {
                if (isSimpCardHolder(_msgSender())) {User.lastSpinTime = uint32(block.timestamp.add(uint(spinFrequencyReduction)));} else {User.lastSpinTime = uint32(block.timestamp);}
            } else {
                User.lastSpinTime = uint32(block.timestamp);
            }

            User.lastDailySpin = User.totalSpins;

        } else {
            uint overrideSpinFee = (uint256(User.totalSpins).sub(User.lastDailySpin)).mul(overrideFee);
            require(msg.value >= (oracle.getbnbusdequivalent(overrideSpinFee)).mul(99).div(100), "Please include the spin fee to spin the SimpWheel");
        }

        uint16 roll;

        roll = uint16(Inserter(directory.getInserter()).getRandMod(randNonce, block.timestamp.add(uint256(keccak256(abi.encodePacked(_msgSender())))%1000000000), 1000));
        
        roll += 1; //normalize 1-1000

        uint16 userReward;
        bool jackpotWinner = false;
        uint jackpotamt;

        payable(this).transfer(msg.value);

        if(roll != winningNumber && !adminWinner) {

            if (roll > winningRoll) { //winning of some kind

                Lotto.globalWins++;

                User.totalWins++;

                if (simpCardBonusEnabled) {
                    if (isSimpCardHolder(_msgSender())) {
                        userReward = uint16(simpWheelBaseReward.add(roll.sub(winningRoll)).div(2));
                        userReward = uint16(userReward.add(userReward.mul(spinResultBonus.add(100)).div(100)));
                    } else {userReward = uint16(simpWheelBaseReward.add(roll.sub(winningRoll)).div(2));}

                } else {
                    userReward = uint16(simpWheelBaseReward.add(roll.sub(winningRoll)).div(2));
                }

                User.totalSBX += uint32(userReward);
                Lotto.globalSBX += uint32(userReward);

                
                if(staked) { //remove if(staked) {} for production, leave function
                    ITeazeFarm(directory.getFarm()).increaseSBXBalance(_msgSender(), userReward.mul(1000000000)); //add 9 zeros
                }

                if(nftbonusenabled) {
                    if(roll >= mintbonuspercent || mintTokenWin) {
                        ITeazeFarm(directory.getFarm()).increaseMintToken(_msgSender());
                    }
                }

                if(discountbonusenabled) {
                    if(roll >= discountbonuspercent || discountTokenWin) {

                        address[] memory discountArray = new address[](3);
                        discountArray[0] = directory.getDiscount1();
                        discountArray[1] = directory.getDiscount2();
                        discountArray[2] = directory.getDiscount3();

                        uint discountRoll = uint16(Inserter(directory.getInserter()).getRandMod(randNonce, block.timestamp.add(uint256(keccak256(abi.encodePacked(_msgSender())))%1000000000), 300));
                        discountRoll = discountRoll.div(100);

                        require(IERC20(discountArray[discountRoll]).balanceOf(address(this)) > 0, "Discount token balance of this contract is insufficient");
                        if(IERC20(discountArray[discountRoll]).balanceOf(_msgSender()) == 0) {
                            IERC20(discountArray[discountRoll]).transfer(_msgSender(), 1000000000); //DiscountToken
                            emit DiscountTokenSent(true);
                        } else {
                            ITeazeFarm(directory.getFarm()).increaseSBXBalance(_msgSender(), 100000000000); //give 100 SBX bonus if discount is already held
                            emit DiscountTokenSent(false);
                        }
                        
                    }
                }


                if (block.timestamp > uint(LastPriceTime).add(priceCheckInterval)) {
                    saveLatestPrice();
                }

                    
            }  else {

                if(address(this).balance > jackpotLimit) {

                    uint256 netamount = address(this).balance.mul(overage).div(100);
                    
                    marketBuy(netamount);

                    jackpotLimit = uint128(uint(jackpotLimit).add(uint(jackpotLimit).mul(overage).div(100)));
                    

                } else {

                    if (block.timestamp > uint(LastPriceTime).add(priceCheckInterval)) {
                        saveLatestPrice();
                    }
                }
                
            }

        } else {

            User.totalWins++;

            Lotto.globalWins++;
            
            Lotto.globalJackpots++;

            jackpotWinner = true;

            User.totalJackpots++;

            uint256 netamount = (address(this).balance.mul(winningPercent).div(100));
            jackpotamt = netamount;

            User.totalJackpotsBNB += uint128(netamount);

            Lotto.globalJackpotsBNB += uint128(netamount);

            payable(_msgSender()).transfer(netamount);

            winningNumber = uint16(Inserter(directory.getInserter()).getRandLotto(randNonce, roll));

            jackpotLimit = uint128(uint(jackpotLimit).div(2));

            emit Jackpot(jackpotamt, roll, _msgSender());

        }

        emit SpinResult(roll, userReward, jackpotWinner, jackpotamt);

    }

    function changeBaseReward(uint8 _baseReward) external onlyAuthorized {
        simpWheelBaseReward = _baseReward;
    }

    function changeFeeReduction(uint8 _feeReduction) external onlyAuthorized {
        feeReduction = _feeReduction;
    }

    function changeOverrideFee(uint8 _overrideFee) external onlyAuthorized {
        overrideFee = _overrideFee;
    }

    function changeJackpotLimit(uint64 _limit) external onlyAuthorized {
        jackpotLimit = _limit;
    }

    function changeMarketBuyGas(uint24 _gas) external onlyAuthorized {
        marketBuyGas = _gas;
    }

    function changeSpinFrequency(uint24 _period) external onlyAuthorized {
        spinFrequency = _period;
    }

    function changeWinningPercent(uint8 _winningPercent) external onlyAuthorized {
        require(_winningPercent <= 100 && _winningPercent > 0, "Winning percent must be between 1 and 100");
        winningPercent = _winningPercent;
    }

    function isSimpCardHolder(address _holder) public view returns (bool) {
        if (IERC721(simpCardContract).balanceOf(_holder) > 0) {return true;} else {return false;}
    }


    function changeSimpCardContract(address _contract) external onlyAuthorized {
        require(_contract != address(0), "Farming contract must not be the zero address");
        simpCardContract = _contract;
    }

    function changeSpinFrequencyRedux(uint16 _period) external onlyAuthorized {
        require(_period <= spinFrequency, "Spin Frequency Reduction must not be greater than spin frequency");
        spinFrequencyReduction = _period;
    }

    function changeSpinResultBonus(uint8 _bonus) external onlyAuthorized {
        require(_bonus <= 50, "SimpBux bonus cannot be more than 50 percent for SimpCard holders");
        spinResultBonus = _bonus;
    }

    function enableSimpCardBonus(bool _status) external onlyAuthorized {
        simpCardBonusEnabled = _status;
    }

    function rescueETHFromContract() external onlyOwner {
        address payable _owner = payable(_msgSender());
        _owner.transfer(address(this).balance);
    }

    function transferERC20Tokens(address _tokenAddr, address _to, uint _amount) public onlyOwner {
       
        IERC20(_tokenAddr).transfer(_to, _amount);
    }
    
    function changeOverage(uint8 _number) external onlyAuthorized {
        require(_number > 0 && _number <= 50, "Jackpot overage should be between 1 and 50 percent of total");
        overage = _number;
    }

    function marketBuy(uint _netamount) internal {

        globalLotteryData storage Lotto = globallotto[0];

        Lotto.globalBNBTeaze += uint128(_netamount);

        uint balanceBefore = IERC20(directory.getTeazeToken()).balanceOf(directory.getFarm());

        IWETH(WETH).deposit{value : _netamount}();
        IWETH(WETH).transfer(directory.getPair(), _netamount);

        uint buyTrigger = returnFeeReduction(overrideFee,feeReduction);
        payable(_msgSender()).transfer(buyTrigger.mul(gasrefund));

        address[] memory path = new address[](2);

        path[0] = WETH;
        path[1] = directory.getTeazeToken();

        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value:buyTrigger, gas:marketBuyGas}(
            0,
            path,
            address(directory.getFarm()),
            block.timestamp
        );

        uint balanceNow = IERC20(directory.getTeazeToken()).balanceOf(directory.getFarm());

        Lotto.globalTeaze += uint128(balanceNow.sub(balanceBefore));

        emit TeazeBuy(_netamount, balanceNow.sub(balanceBefore));

    }

    function setAdminWinnner(bool _status) external onlyAuthorized { //remove for production
        adminWinner = _status;
    }

    function setNFTtokenMint(bool _status) external onlyAuthorized {
        nftbonusenabled = _status;
    }

    function setDiscountEnabled(bool _status) external onlyAuthorized {
        discountbonusenabled = _status;
    }

    function getWinningNumber() external view returns (uint) { //remove for production
        return winningNumber;
    }

    function changeOracle(address _oracle) external onlyAuthorized {
        oracle = IOracle(_oracle);
    }

    function saveLatestPrice() internal {

        LastPriceTime = block.timestamp;

        (,,uint lastPrice) = oracle.getTeazeUSDPrice();
        
        emit PriceHistory(LastPriceTime, lastPrice);
    }

    function getNewWinningNumber() external onlyAuthorized {
        winningNumber = uint16(Inserter(directory.getInserter()).getRandLotto(randNonce, winningNumber));
    }

    function returnFeeReduction(uint _amount, uint _reduction) public view returns (uint) {
        return (oracle.getbnbusdequivalent(_amount).div(_reduction));
    }

    function changePriceCheckInterval(uint32 _priceCheckInterval) external onlyAuthorized {
        require(priceCheckInterval > 0 , "Price check interval must be greater than 0");
        priceCheckInterval = _priceCheckInterval;
    }

    function changeWinningRoll(uint16 _number) external onlyAuthorized {
        winningRoll = _number;
    }

    function updateGlobalLotteryNumbers() internal {

        globalLotteryData storage lotto = globallotto[0];
        
        (lotto.globalSpins,
        lotto.globalWins,
        lotto.globalSBX,
        lotto.globalTeaze,
        lotto.globalBNBTeaze,
        ,
        ) = LastLotto(lastLottery).globallotto(0);
        
    }

    function updateUserNumbers(address _holder) internal {
        userLotteryData storage user = userlotto[_holder];

        (user.lastSpinTime,
        user.lastDailySpin,
        user.totalSBX,
        user.totalSpins,
        user.totalWins,
        ,
        ) = LastLotto(lastLottery).userlotto(_holder);

    }

    function updateUserJackpotData(address _holder) internal {
        userLotteryData storage userStackTooDeep = userlotto[_holder];

        (,,,,,userStackTooDeep.totalJackpots,
        userStackTooDeep.totalJackpotsBNB) = LastLotto(lastLottery).userlotto(_holder);
    }

    function updateGlobalJackpotData() internal {
        globalLotteryData storage LottoStackTooDeep = globallotto[0];

        (,,,,,LottoStackTooDeep.globalJackpots,
        LottoStackTooDeep.globalJackpotsBNB) = LastLotto(lastLottery).globallotto(0);
    }

    function changeDirectory(address _directory) external onlyAuthorized {
        directory = Directory(_directory);
    }

}
