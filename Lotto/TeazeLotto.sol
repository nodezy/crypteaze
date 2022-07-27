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
        require(authorized[_msgSender()] || owner() == address(_msgSender()));
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

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint value) external returns (bool);
    function approve(address spender, uint value) external returns (bool);
    function balanceOf(address owner) external view returns (uint);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
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
        uint32 lastSpinTime; //Mapping for last user spin on the SimpWheel of Fortune
        uint32 lastDailySpin; //Mapping for last user daily spin on the SimpWheel of Fortune
        uint32 totalSBX; //Mapping for total SBX won on the SimpWheel of Fortune
        uint32 totalSpins; //Mapping for total user spins on the SimpWheel of Fortune
        uint32 totalWins; //Mapping for total user wins on the SimpWheel of Fortune
        uint128 totalJackpots; //Mapping for total user jackpots on the SimpWheel of Fortune
        uint128 totalJackpotsBNB; //Mapping for total user jackpot BNB on the SimpWheel of Fortune
    }

    mapping(uint256 => globalLotteryData) public globallotto; // Info of each NFT artist/infuencer wallet.
    mapping(address => userLotteryData) public userlotto; // Info of each NFT artist/infuencer wallet.
    
    IOracle public oracle;
    IERC20 simpbux;
    IDEXRouter router;
    Inserter private inserter;

    address public farmingContract;
    address public simpCardContract;
    address teazetoken = 0xdD2d44c2776f3e1845c20ce32685A3d73BD44522; //teaze token
    address pair;
    address WETH;

    uint8 public feeReduction = 4; //amount we want overrideFee reduced for spin & trigger fees
    uint8 public overrideFee = 1;  //override fee in whole USD  
    uint8 public winningPercent = 50;
    uint8 public spinResultBonus = 10;
    uint8 public overage = 10; 
    uint16 simpWheelBaseReward = 25;
    uint16 winningNumber; //remove for production
    uint16 public spinFrequencyReduction = 3600;
    uint24 marketBuyGas = 200000;  
    uint24 public spinFrequency = 600;    //18000 for production
    uint32 public priceCheckInterval = 900;   //3600 for production
    uint64 public jackpotLimit = 2 ether;
    uint128 public blockstart = uint128(block.timestamp);
    uint256 public LastPriceTime;
    uint256 private randNonce;
    
    bool public adminWinner = false; //to test winning jackpot roll, remove for production
    bool public simpCardBonusEnabled = false;
    
    event SpinResult(uint indexed roll, uint indexed userReward, bool indexed jackpotWinner, uint jackpotamount);
    event TeazeBuy(uint indexed amountBNB, uint indexed amountTeaze);
    event Jackpot(uint indexed amountBNB, uint indexed winningNumber, address indexed winner);
    event PriceHistory(uint indexed timestamp, uint indexed price);

    constructor(address _farmingContract, address _router, address _pair, address _inserter, address _oracle, uint16 _winningNumber) {
       farmingContract = _farmingContract;
       pair = _pair;
       authorized[owner()] = true;
       inserter = Inserter(_inserter);
       randNonce = inserter.getNonce();
       inserter.makeActive();
       oracle = IOracle(_oracle);
       winningNumber = _winningNumber;

       router = _router != address(0)
            ? IDEXRouter(_router)
            : IDEXRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E); //0xCc7aDc94F3D80127849D2b41b6439b7CF1eB4Ae0 pcs test router
        WETH = router.WETH();
    }
    
    receive() external payable {}


    function SpinSimpWheel(bool _override) external payable nonReentrant {

        globalLotteryData storage Lotto = globallotto[0];
        userLotteryData storage User = userlotto[_msgSender()];
        
        randNonce++;

        Lotto.globalSpins++;

        User.totalSpins++;
        
        
        bool staked = ITeazeFarm(farmingContract).getUserStaked(_msgSender());

       // require(staked, "User must be staked to spin the SimpWheel of Fortune");
    
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

        roll = uint16(Inserter(inserter).getRandMod(randNonce, block.timestamp.add(uint256(keccak256(abi.encodePacked(_msgSender())))%1000000000), 1000));
        
        roll += 1; //normalize 1-1000

        uint16 userReward;
        bool jackpotWinner = false;
        uint jackpotamt;

        payable(this).transfer(msg.value);

        if(roll != winningNumber && !adminWinner) {

            if (roll > 499) { //winning of some kind

                Lotto.globalWins++;

                User.totalWins++;

                if (simpCardBonusEnabled) {
                    if (isSimpCardHolder(_msgSender())) {
                        userReward = uint16(simpWheelBaseReward.add(roll.sub(499)).div(2));
                        userReward = uint16(userReward.add(userReward.mul(spinResultBonus.add(100)).div(100)));
                    } else {userReward = uint16(simpWheelBaseReward.add(roll.sub(499)).div(2));}

                } else {
                    userReward = uint16(simpWheelBaseReward.add(roll.sub(499)).div(2));
                }

                User.totalSBX += uint32(userReward);
                Lotto.globalSBX += uint32(userReward);

                
                if(staked) {
                    ITeazeFarm(farmingContract).increaseSBXBalance(_msgSender(), userReward.mul(1000000000)); //add 9 zeros
                }


                if (block.timestamp > uint(LastPriceTime).add(priceCheckInterval)) {
                    saveLatestPrice();
                }

                    
            }  else {

                if(address(this).balance > jackpotLimit) {

                    uint256 netamount = address(this).balance.mul(overage).div(100);
                    
                    marketBuy(netamount);

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

            winningNumber = uint16(Inserter(inserter).getRandLotto(randNonce, roll));

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

    function changeFarmingContract(address _contract) external onlyAuthorized {
        require(_contract != address(0), "Farming contract must not be the zero address");
        farmingContract = _contract;
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

    // This will allow to rescue ETH sent by mistake directly to the contract
    function rescueETHFromContract() external onlyOwner {
        address payable _owner = payable(_msgSender());
        _owner.transfer(address(this).balance);
    }

    // Function to allow admin to claim *other* ERC20 tokens sent to this contract (by mistake)
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

        uint balanceBefore = IERC20(teazetoken).balanceOf(farmingContract);

        IWETH(WETH).deposit{value : _netamount}();
        IWETH(WETH).transfer(pair, _netamount);

        uint buyTrigger = returnFeeReduction(overrideFee,feeReduction);
        payable(_msgSender()).transfer(buyTrigger);

        address[] memory path = new address[](2);

        path[0] = WETH;
        path[1] = teazetoken;

        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value:buyTrigger, gas:marketBuyGas}(
            0,
            path,
            address(farmingContract),
            block.timestamp
        );

        uint balanceNow = IERC20(teazetoken).balanceOf(farmingContract);

        Lotto.globalTeaze += uint128(balanceNow.sub(balanceBefore));

        emit TeazeBuy(_netamount, balanceNow.sub(balanceBefore));

    }

    function setAdminWinnner(bool _status) external onlyOwner {
        adminWinner = _status;
    }

    function getWinningNumber() external view returns (uint) {
        return winningNumber;
    }

    function changeOracle(address _oracle) external onlyOwner {
        oracle = IOracle(_oracle);
    }

    function saveLatestPrice() internal {

        LastPriceTime = block.timestamp;

        (,,uint lastPrice) = oracle.getTeazeUSDPrice();
        
        emit PriceHistory(LastPriceTime, lastPrice);
    }

    function getNewWinningNumber() external onlyAuthorized {
        winningNumber = uint16(Inserter(inserter).getRandLotto(randNonce, winningNumber));
    }

    function returnFeeReduction(uint _amount, uint _reduction) public view returns (uint) {
        return (oracle.getbnbusdequivalent(_amount).div(_reduction));
    }

    function changePriceCheckInterval(uint32 _priceCheckInterval) external onlyAuthorized {
        require(priceCheckInterval > 0 , "Price check interval must be greater than 0");
        priceCheckInterval = _priceCheckInterval;
    }


}
