// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

interface IBEP20 {
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function name() external view returns (string memory);
    function getOwner() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address _owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

interface AggregatorV3Interface {
  function decimals() external view returns (uint8);

  function description() external view returns (string memory);

  function version() external view returns (uint256);

  // getRoundData and latestRoundData should both raise "No data present"
  // if they do not have data to report, instead of returning unset values
  // which could be misinterpreted as actual reported values.
  function getRoundData(uint80 _roundId)
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );

  function latestRoundData()
    external
    view
    returns (
      uint80 roundId,
      uint256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );
}

interface IPancakePair {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external pure returns (string memory);
    function symbol() external pure returns (string memory);
    function decimals() external pure returns (uint8);
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    function nonces(address owner) external view returns (uint);

    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    function MINIMUM_LIQUIDITY() external pure returns (uint);
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint);
    function price1CumulativeLast() external view returns (uint);
    function kLast() external view returns (uint);

    function mint(address to) external returns (uint liquidity);
    function burn(address to) external returns (uint amount0, uint amount1);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;

    function initialize(address, address) external;
}

interface Directory {
    function getPair() external view returns (address);
}

contract TeazeOracle is Ownable {

    using SafeMath for uint256;

    AggregatorV3Interface internal priceFeed;
    Directory public directory;
    
    uint256 setPrice = 500; //public sale price, sets the bottom limit for dynamic discount

    constructor(address _directory) {
        priceFeed = AggregatorV3Interface(0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526);  //bscmainet bnb/usd 0x0567f2323251f0aab15c8dfb1967e4e8a7d42aee
        directory = Directory(_directory);
    }

    receive() external payable {}

    /**
     * Returns the latest price
     */
    function getLatestPrice() public view returns (uint256) {
        (
            uint80 roundID, 
            uint256 price,
            uint startedAt,
            uint timeStamp,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();
        return price;
    }

    function getReserves() public view returns (uint256 reserve0, uint256 reserve1) {
      (uint256 Res0, uint256 Res1,) = IPancakePair(directory.getPair()).getReserves();
      return (Res0, Res1);
    }

    function getTeazeUSDPrice() public view returns (uint256, uint256, uint256) {

      uint256 bnbusdprice = getLatestPrice();
      bnbusdprice = bnbusdprice.mul(10); //make bnb usd price have 9 decimals
      
      (uint256 pooledBNB, uint256 pooledTEAZE) = getReserves();

      IBEP20 token0 = IBEP20(IPancakePair(directory.getPair()).token0()); //BNB
      IBEP20 token1 = IBEP20(IPancakePair(directory.getPair()).token1()); //TEAZE  

      pooledBNB = pooledBNB.div(10**token1.decimals()); //divide by non-BNB token decimals

      uint256 pooledBNBUSD = pooledBNB.mul(bnbusdprice); //multiply pooled bnb x usd price of 1 bnb
      uint256 teazeUSD = pooledBNBUSD.div(pooledTEAZE); //divide pooled bnb usd price by amount of pooled TEAZE
  
      return (bnbusdprice, pooledBNBUSD, teazeUSD);
    }

    //for the token contract dynamic discount
    function getdiscount(uint256 amount) external view returns (uint256) {
      (uint256 bnbusd,,uint256 teazeusd) = getTeazeUSDPrice();
      uint256 teazeusdtemp;
      if (teazeusd < setPrice) {teazeusdtemp = setPrice;} else {teazeusdtemp = teazeusd;}
      uint256 totalteazeusd = teazeusdtemp.mul(amount);
      uint256 totalbnb = totalteazeusd.div(bnbusd);
      if (teazeusd < setPrice) {
        totalbnb = totalbnb.div(2);
      }
      return totalbnb;
    }

    //Get Teaze equivalent of BNB input
    function getbnbequivalent(uint256 amount) external view returns (uint256) {
      (uint256 bnbusd,,uint256 teazeusd) = getTeazeUSDPrice();
      if (teazeusd < setPrice) {
        teazeusd = setPrice;
      }
      uint256 tempbnbusd = amount.mul(bnbusd);
      uint256 tempteaze = tempbnbusd.div(teazeusd);

      return tempteaze.div(10**9);
    }

    function getbnbusdequivalent(uint256 amount) external view returns (uint256) {
      uint256 bnbusdprice = getLatestPrice();
      bnbusdprice = bnbusdprice.mul(10); //make bnb usd price have 9 decimals
      uint256 bnb = 1000000000000000000;
      uint bnbfactor = bnb.div(bnbusdprice);
      return (amount.mul(bnbfactor.mul(10**9)));
    }

    function TZOnline() external pure returns (bool) {
      return true;
    }
    
    function changeSetPrice(uint256 _amount) external onlyOwner {
      setPrice = _amount;
    }

    function rescueBNBFromContract() external onlyOwner {
        address payable _owner = payable(_msgSender());
        _owner.transfer(address(this).balance);
    }

    function transferBEP20Tokens(address _tokenAddr, address _to, uint _amount) external onlyOwner {
       
        IBEP20(_tokenAddr).transfer(_to, _amount);
    }

    function changeDirectory(address _directory) external onlyOwner {
        directory = Directory(_directory);
    }
}
