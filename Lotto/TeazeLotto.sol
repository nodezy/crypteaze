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

interface ITeazeFarm {
    function getUserStaked(address _holder) external view returns (bool);
    function increaseSBXBalance(address _address, uint256 _amount) external;
}

interface Inserter {
    function makeActive() external; 
    function getNonce() external view returns (uint256);
    function getRandMod(uint256 _extNonce, uint256 _modifier, uint256 _modulous) external view returns (uint256);
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

    address farmingContract;
    address simpCardContract;
    IERC20 simpbux;

    mapping(address => uint256) public lastSpin; //Mapping for last user spin on the SimpWheel of Fortune
    uint simpWheelBaseReward = 25;
    uint public spinFee = 0.0005 ether; //Fee the contract takes for each attempt at spinning the SimpWheel

    address teazetoken = 0xdD2d44c2776f3e1845c20ce32685A3d73BD44522; //teaze token
    address pair;

    IDEXRouter router;
    
    address WETH;
    Inserter public inserter;
    uint256 private randNonce;

    uint marketBuyGas = 450000;
    uint jackpotLimit = 2 ether;
    uint winningPercent = 50;
    uint spinFrequency = 86400;
    uint spinFrequencyReduction = 14400;
    uint spinResultBonus = 10;
    bool simpCardBonusEnabled = false;

    uint buyTrigger = 0.001 ether; //Amount of BNB the user will have to pay to trigger a buy if jackpot is over upper limit. This amount will be returned to the user in the same transaction

    constructor(address _farmingContract, address _router, address _pair, address _inserter) {
       farmingContract = _farmingContract;
       pair = _pair;
       authorized[owner()] = true;
       inserter = Inserter(_inserter);
       randNonce = inserter.getNonce();
       inserter.makeActive();

       router = _router != address(0)
            ? IDEXRouter(_router)
            : IDEXRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E); //0xCc7aDc94F3D80127849D2b41b6439b7CF1eB4Ae0 pcs test router
        WETH = router.WETH();
    }
    
    receive() external payable {}


    function SpinSimpWheel(address _holder) external payable nonReentrant returns (uint256 userroll,uint256 simbuxwinnings,bool jackpotwinner) {

        bool staked = ITeazeFarm(farmingContract).getUserStaked(_holder);
        require(_msgSender() == address(farmingContract), "Spinning not allowed outside of the farming contract");
        require(staked, "User must be staked to spin the SimpWheel of Fortune");
        if(lastSpin[_holder] != 0) {
            require(block.timestamp.sub(lastSpin[_holder]) >= spinFrequency, "Not eligible to spin yet");
        }
        require(msg.value == spinFee, "Please include the spin fee to spin the SimpWheel");

        uint256 roll;

        roll = Inserter(inserter).getRandMod(randNonce, uint8(uint256(keccak256(abi.encodePacked(_holder)))%100), 1000);
        
        roll = roll.add(1); //normalize 1-1000

        uint256 userReward;
        bool jackpotWinner = false;

        payable(this).transfer(spinFee);

        if (simpCardBonusEnabled) {
            if (isSimpCardHolder(_holder)) {lastSpin[_holder] = block.timestamp.add(spinFrequencyReduction);} else {lastSpin[_holder] = block.timestamp;}
        } else {
            lastSpin[_holder] = block.timestamp;
        }
        

        if (roll > 499) { //winning of some kind

            //(userRoll - 500) + baseReward) / 2 

            if (simpCardBonusEnabled) {
                if (isSimpCardHolder(_holder)) {
                    userReward = (simpWheelBaseReward.add(roll.sub(499))).div(2);
                    userReward = userReward.add(userReward.mul(spinResultBonus.add(100)).div(100));
                } else {userReward = (simpWheelBaseReward.add(roll.sub(499))).div(2);}

            } else {
                userReward = (simpWheelBaseReward.add(roll.sub(499))).div(2);
            }
            
            ITeazeFarm(farmingContract).increaseSBXBalance(_holder, userReward);

            if (roll == 1000) { //wins jackpot

            jackpotWinner = true;
            payable(_holder).transfer(address(this).balance.mul(winningPercent).div(100));

            } else {
                if(address(this).balance > jackpotLimit) {

                    uint256 netamount = address(this).balance.mul(20).div(100);
                    IWETH(WETH).deposit{value : netamount}();
                    IWETH(WETH).transfer(pair, netamount);

                    payable(_holder).transfer(buyTrigger);

                    address[] memory path = new address[](2);

                    path[0] = WETH;
                    path[1] = teazetoken;

                    router.swapExactETHForTokensSupportingFeeOnTransferTokens{value:buyTrigger, gas:marketBuyGas}(
                        0,
                        path,
                        address(farmingContract),
                        block.timestamp
                    );
                }
            }

            return(roll,userReward,jackpotWinner);


        } else {
            return (roll,0, false);
        }       
        
    }

    function changeBaseReward(uint256 _baseReward) external onlyAuthorized {
        simpWheelBaseReward = _baseReward;
    }

    function changeSpinFee(uint256 _spinFee) external onlyAuthorized {
        spinFee = _spinFee;
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

    function changeBuyTrigger(uint256 _buyTrigger) external onlyAuthorized {
        buyTrigger = _buyTrigger;
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

}
