// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/utils/Counters.sol";
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
    using SafeERC20 for IERC20;
    using Counters for Counters.Counter;

    struct priceHistory {
        uint lastPrice;
        uint priceTime;
    }

    Counters.Counter public _historyID;

    IOracle public oracle;
    mapping(uint256 => priceHistory) public pricehistory; // Info of each NFT artist/infuencer wallet.
    uint public lastPriceCheck;
    uint public priceCheckInterval = 60;
    uint[] priceHistoryArray;

    address public farmingContract;
    address public simpCardContract;
    IERC20 simpbux;

    address teazetoken = 0xdD2d44c2776f3e1845c20ce32685A3d73BD44522; //teaze token
    address pair;

    IDEXRouter router;
    
    address WETH;
    Inserter private inserter;
    uint256 private randNonce;

    mapping(address => uint256) public lastSpinTime; //Mapping for last user spin on the SimpWheel of Fortune
    mapping(address => uint256) public lastDailySpin; //Mapping for last user daily spin on the SimpWheel of Fortune
    mapping(address => uint256) public totalSBX; //Mapping for total SBX won on the SimpWheel of Fortune
    mapping(address => uint256) public totalSpins; //Mapping for total user spins on the SimpWheel of Fortune
    mapping(address => uint256) public totalWins; //Mapping for total user wins on the SimpWheel of Fortune
    mapping(address => uint256) public totalJackpots; //Mapping for total user jackpots on the SimpWheel of Fortune
    mapping(address => uint256) public totalJackpotsBNB; //Mapping for total user jackpot BNB on the SimpWheel of Fortune
    
    uint marketBuyGas = 200000;
    uint simpWheelBaseReward = 25;
    uint public feeReduction = 4; //amount we want overrideFee reduced for spin & trigger fees
    uint public overrideFee = 1;  //override fee in whole USD    
    uint public jackpotLimit = 2 ether;
    uint public winningPercent = 50;
    uint public spinFrequency = 86400;
    uint public spinFrequencyReduction = 14400;
    uint public spinResultBonus = 10;
    bool public simpCardBonusEnabled = false;
    uint public overage = 10;
    uint public totalTeaze;
    uint public globalSpins;
    uint public globalSBX;
    uint public globalWins;
    uint public globalJackpots;
    uint public globalBNBJackpots;
    uint public globalBNBTeaze;
    bool public adminWinner = false; //to test winning jackpot roll, remove for production
    uint winningNumber; //remove for production
    
    event SpinResult(uint indexed roll, uint indexed userReward, bool indexed jackpotWinner, uint jackpotamount);

    constructor(address _farmingContract, address _router, address _pair, address _inserter, address _oracle, uint _winningNumber) {
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

        randNonce++;

        globalSpins++;

        totalSpins[_msgSender()] = totalSpins[_msgSender()] + 1;
        
        bool staked = ITeazeFarm(farmingContract).getUserStaked(_msgSender());

       // require(staked, "User must be staked to spin the SimpWheel of Fortune");
    
        if(!_override) {
            if(lastSpinTime[_msgSender()] != 0) {
                require(block.timestamp.sub(lastSpinTime[_msgSender()]) >= spinFrequency, "Not eligible to spin yet");
            }
            require(msg.value >= returnFeeReduction(overrideFee,feeReduction).mul(99).div(100), "Please include the spin fee to spin the SimpWheel");
            
            if (simpCardBonusEnabled) {
                if (isSimpCardHolder(_msgSender())) {lastSpinTime[_msgSender()] = block.timestamp.add(spinFrequencyReduction);} else {lastSpinTime[_msgSender()] = block.timestamp;}
            } else {
                lastSpinTime[_msgSender()] = block.timestamp;
            }

            lastDailySpin[_msgSender()] = totalSpins[_msgSender()];

        } else {
            uint overrideSpinFee = (totalSpins[_msgSender()].sub(lastDailySpin[_msgSender()])).mul(overrideFee);
            require(msg.value >= (oracle.getbnbusdequivalent(overrideSpinFee)).mul(99).div(100), "Please include the spin fee to spin the SimpWheel");
        }

        uint256 roll;

        roll = Inserter(inserter).getRandMod(randNonce, block.timestamp.add(uint256(keccak256(abi.encodePacked(_msgSender())))%1000000000), 1000);
        
        roll = roll.add(1); //normalize 1-1000

        uint256 userReward = 0;
        bool jackpotWinner = false;
        uint jackpotamt = 0;

        payable(this).transfer(msg.value);

        

        if(roll != winningNumber && !adminWinner) {

            if (roll > 499) { //winning of some kind

                globalWins++;

                totalWins[_msgSender()] = totalWins[_msgSender()] + 1;

                if (simpCardBonusEnabled) {
                    if (isSimpCardHolder(_msgSender())) {
                        userReward = (simpWheelBaseReward.add(roll.sub(499))).div(2);
                        userReward = userReward.add(userReward.mul(spinResultBonus.add(100)).div(100));
                    } else {userReward = (simpWheelBaseReward.add(roll.sub(499))).div(2);}

                } else {
                    userReward = (simpWheelBaseReward.add(roll.sub(499))).div(2);
                }

                totalSBX[_msgSender()] = totalSBX[_msgSender()] + userReward;
                globalSBX = globalSBX.add(userReward);
                
                if(staked) {
                    ITeazeFarm(farmingContract).increaseSBXBalance(_msgSender(), userReward.mul(1000000000)); //add 9 zeros
                }
                    
            }  else {

                if(address(this).balance > jackpotLimit) {

                    uint256 netamount = address(this).balance.mul(overage).div(100);
                    
                    marketBuy(netamount);
                }
            }

        } else {

            globalJackpots++;

            jackpotWinner = true;

            totalJackpots[_msgSender()] = totalJackpots[_msgSender()] + 1;

            uint256 netamount = (address(this).balance.mul(winningPercent).div(100));
            jackpotamt = netamount;
            totalJackpotsBNB[_msgSender()] = totalJackpotsBNB[_msgSender()] + netamount;

            globalBNBJackpots = globalBNBJackpots + netamount;

            payable(_msgSender()).transfer(netamount);

            winningNumber = Inserter(inserter).getRandLotto(randNonce, roll);

        }

        if (block.timestamp > lastPriceCheck.add(priceCheckInterval)) {
            saveLatestPrice();
        }

        emit SpinResult(roll, userReward, jackpotWinner, jackpotamt);

    }

    function changeBaseReward(uint256 _baseReward) external onlyAuthorized {
        simpWheelBaseReward = _baseReward;
    }

    function changeFeeReduction(uint256 _feeReduction) external onlyAuthorized {
        feeReduction = _feeReduction;
    }

    function changeOverrideFee(uint256 _overrideFee) external onlyAuthorized {
        overrideFee = _overrideFee;
    }

    function changeJackpotLimit(uint256 _limit) external onlyAuthorized {
        jackpotLimit = _limit;
    }

    function changeMarketBuyGas(uint256 _gas) external onlyAuthorized {
        marketBuyGas = _gas;
    }

    function changeSpinFrequency(uint256 _period) external onlyAuthorized {
        spinFrequency = _period;
    }

    function changeWinningPercent(uint256 _winningPercent) external onlyAuthorized {
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

    function changeSpinFrequencyRedux(uint _period) external onlyAuthorized {
        require(_period <= 43200, "Spin Frequency Reduction must not be greater than 12 hours");
        spinFrequencyReduction = _period;
    }

    function changeSpinResultBonus(uint _bonus) external onlyAuthorized {
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

    
    function changeOverage(uint _number) external onlyAuthorized {
        require(_number > 0 && _number <= 50, "Jackpot overage should be between 1 and 50 percent of total");
        overage = _number;
    }

    function marketBuy(uint _netamount) internal {

        globalBNBTeaze = globalBNBTeaze.add(_netamount);

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

        totalTeaze = totalTeaze.add(balanceNow.sub(balanceBefore));

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

         _historyID.increment();

        uint256 _history = _historyID.current();
        priceHistoryArray.push(_history);

        (,,uint lastPrice) = oracle.getTeazeUSDPrice();
        
        priceHistory storage prices = pricehistory[_history];
        prices.lastPrice = lastPrice;
        prices.priceTime = block.timestamp;

        lastPriceCheck = block.timestamp;
    }

    function getPriceHistory(uint period) external view returns (uint256[] memory, uint256[] memory) {

        uint arraylength = priceHistoryArray.length;

        if (arraylength < period) {period = arraylength;}

        uint256[] memory price = new uint256[](period);
        uint256[] memory time = new uint256[](period);
        uint256 count = 0;

        for (uint256 x = 1; x <= period; ++x) {

            priceHistory storage prices = pricehistory[arraylength-x];
            price[count] = prices.lastPrice;
            time[count] = prices.priceTime;
            count++;

        }

        return (price, time);

    }

    function getNewWinningNumber() external onlyAuthorized {
        winningNumber = Inserter(inserter).getRandLotto(randNonce, winningNumber);
    }

    function returnFeeReduction(uint _amount, uint _reduction) public view returns (uint) {
        return (oracle.getbnbusdequivalent(_amount).div(_reduction));
    }


}
