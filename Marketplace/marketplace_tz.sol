// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface Directory {
    function getNFT() external view returns (address);
    function getPacks() external view returns (address);
    function getCrates() external view returns (address);
}

contract TeazeMarketplace is Ownable, IERC721Receiver, ReentrancyGuard {
    using Counters for Counters.Counter;
    using SafeMath for uint256;

    Counters.Counter private _itemsHeld;
    Counters.Counter private _itemsSold;

    uint256 listingFee = 0.0025 ether;
    uint256 buyingFee = 0.0025 ether;
    
    mapping(uint256 => MarketItem) private idToMarketItem;
    
    struct MarketItem {
      uint256 tokenId;
      address payable seller;
      address payable owner;
      uint256 price;
      bool sold;
    }

    event MarketItemCreated (
      uint256 indexed tokenId,
      address seller,
      address owner,
      uint256 price,
      bool sold
    );

    Directory public directory;
    uint256 public feeTotals;

    constructor(address _directory)  {
      directory = Directory(_directory);
    }   

    receive() external payable {}

    /* Updates the listing price of the contract */
    function updatelistingFee(uint _listingFee) external onlyOwner {
      listingFee = _listingFee;
    }

    /* Updates the buying price of the contract */
    function updatebuyingFee(uint _buyingFee) external onlyOwner {
      buyingFee = _buyingFee;
    }

    /* Returns the listing price of the contract */
    function getlistingFee() public view returns (uint256) {
      return listingFee;
    }

    function getbuyingFee() public view returns (uint256) {
      return buyingFee;
    }

    function createMarketItem(
      uint256 tokenId,
      uint256 price
    ) external payable nonReentrant {
      require(price > 0, "Price must be at least 1 wei");
      require(msg.value == listingFee, "Please include listing fee in order to list the item");

      idToMarketItem[tokenId] =  MarketItem(
        tokenId,
        payable(msg.sender),
        payable(address(this)),
        price,
        false
      );

      IERC721(directory.getNFT()).safeTransferFrom(msg.sender, address(this), tokenId);

      payable(directory.getCrates()).transfer(listingFee);

      feeTotals = feeTotals.add(listingFee);

      _itemsHeld.increment();
      
      emit MarketItemCreated(
        tokenId,
        msg.sender,
        address(this),
        price,
        false
      );
    }

    /* allows someone to remove a token they have listed */
    function removeMarketItem(uint256 tokenId) external nonReentrant {
      require(idToMarketItem[tokenId].owner == msg.sender, "Only item owner can perform this operation");
      //require(msg.value == listingFee, "Price must be equal to listing price");
      idToMarketItem[tokenId].sold = false;
      idToMarketItem[tokenId].price = 0;
      idToMarketItem[tokenId].seller = payable(address(0));
      idToMarketItem[tokenId].owner = payable(address(0));
      _itemsHeld.decrement();

      IERC721(directory.getNFT()).safeTransferFrom(address(this), msg.sender, tokenId);
    }

    /* Creates the sale of a marketplace item */
    /* Transfers ownership of the item, as well as funds between parties */
    function createMarketSale(
      uint256 tokenId
      ) external payable nonReentrant {
      uint price = idToMarketItem[tokenId].price;
      address seller = idToMarketItem[tokenId].seller;
      require(msg.value == price.add(buyingFee), "Please submit the asking price + fee in order to complete the purchase");
      idToMarketItem[tokenId].owner = payable(msg.sender);
      idToMarketItem[tokenId].sold = true;
      idToMarketItem[tokenId].seller = payable(address(0));
      _itemsHeld.decrement();
      _itemsSold.increment();
      IERC721(directory.getNFT()).safeTransferFrom(address(this), msg.sender, tokenId);
      payable(directory.getCrates()).transfer(buyingFee);
      feeTotals = feeTotals.add(buyingFee);
      payable(seller).transfer(msg.value.sub(buyingFee));
    }

    /* Returns all unsold market items */
    function fetchMarketItems() public view returns (MarketItem[] memory) {
      uint itemCount = _itemsHeld.current();
      uint unsoldItemCount = _itemsHeld.current() - _itemsSold.current();
      uint currentIndex = 0;

      MarketItem[] memory items = new MarketItem[](unsoldItemCount);
      for (uint i = 0; i < itemCount; i++) {
        if (idToMarketItem[i + 1].owner == address(this)) {
          uint currentId = i + 1;
          MarketItem storage currentItem = idToMarketItem[currentId];
          items[currentIndex] = currentItem;
          currentIndex += 1;
        }
      }
      return items;
    }

    /* Returns only items that a user has purchased */
    function fetchMyNFTs() public view returns (MarketItem[] memory) {
      uint totalItemCount = _itemsHeld.current();
      uint itemCount = 0;
      uint currentIndex = 0;

      for (uint i = 0; i < totalItemCount; i++) {
        if (idToMarketItem[i + 1].owner == msg.sender) {
          itemCount += 1;
        }
      }

      MarketItem[] memory items = new MarketItem[](itemCount);
      for (uint i = 0; i < totalItemCount; i++) {
        if (idToMarketItem[i + 1].owner == msg.sender) {
          uint currentId = i + 1;
          MarketItem storage currentItem = idToMarketItem[currentId];
          items[currentIndex] = currentItem;
          currentIndex += 1;
        }
      }
      return items;
    }

    /* Returns only items a user has listed */
    function fetchItemsListed() public view returns (MarketItem[] memory) {
      uint totalItemCount = _itemsHeld.current();
      uint itemCount = 0;
      uint currentIndex = 0;

      for (uint i = 0; i < totalItemCount; i++) {
        if (idToMarketItem[i + 1].seller == msg.sender) {
          itemCount += 1;
        }
      }

      MarketItem[] memory items = new MarketItem[](itemCount);
      for (uint i = 0; i < totalItemCount; i++) {
        if (idToMarketItem[i + 1].seller == msg.sender) {
          uint currentId = i + 1;
          MarketItem storage currentItem = idToMarketItem[currentId];
          items[currentIndex] = currentItem;
          currentIndex += 1;
        }
      }
      return items;
    }

     function onERC721Received(address, address, uint256, bytes memory) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
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

    function changeDirectory(address _directory) external onlyOwner {
        directory = Directory(_directory);
    }
}
