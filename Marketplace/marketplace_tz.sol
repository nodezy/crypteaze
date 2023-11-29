// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./auth.sol";

interface ITeazeNFT {
    function tokenURI(uint256 tokenId) external view returns (string memory); 
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
    function getUserTokenIDtoNFTID(address _holder, uint _tokenID) external view returns (uint256);
}

interface ITeazePacks {
    function getNFTURI(uint256 _nftid) external view returns (string memory);
    function getPackIDbyNFT(uint256 _nftid) external view returns (uint256);
    function getIDbyURI(string memory _uri) external view returns (uint256);
}

interface IDirectory {
    function getInserter() external view returns (address);
    function getNFT() external view returns (address);
    function getPacks() external view returns (address);
}

contract TeazeMarket is Ownable, Authorizable, IERC721Receiver, ReentrancyGuard {
    using Counters for Counters.Counter;
    using SafeMath for uint256;

    Counters.Counter public _itemsHeld;
    Counters.Counter public _itemsSold;
    Counters.Counter public _itemsTotal;

    uint256 listingFee = 0.0025 ether;
    uint256 buyingFee = 0.0025 ether;
    
    mapping(uint256 => MarketItem) public idToMarketItem;
    uint256[] public heldtokens;
    uint256[] public soldtokens;
    
    struct MarketItem {
      uint256 tokenId;
      uint256 price;
      uint128 nftid;
      uint128 pack;
      address payable seller;
      address payable owner;
      bool sold;
    }

    event MarketItemCreated (
      address indexed seller,
      uint256 tokenId,
      uint256 price,
      uint256 time
    );

    event MarketItemSold (
      address indexed seller,
      address indexed buyer,
      uint256 tokenId,
      uint256 price,
      bool sold,
      uint256 time
    );

    bool public production = false;
    uint256 public feeTotals;
    
    IDirectory public directory;

    constructor(address _directory) {
        directory = IDirectory(_directory);
        authorized[owner()] = true;
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
      
      if(production) {
        
      }

      heldtokens.push(tokenId);

      idToMarketItem[tokenId].tokenId = tokenId;
      idToMarketItem[tokenId].price = price;

      uint _nftid = ITeazeNFT(directory.getNFT()).getUserTokenIDtoNFTID(_msgSender(), tokenId); 
      uint _packid = ITeazePacks(directory.getPacks()).getPackIDbyNFT(_nftid);

      idToMarketItem[tokenId].nftid = uint128(_nftid); 
      idToMarketItem[tokenId].pack = uint128(_packid);
      idToMarketItem[tokenId].seller = payable(_msgSender());
      idToMarketItem[tokenId].owner = payable(address(this));
      idToMarketItem[tokenId].sold = false;

      IERC721(directory.getNFT()).safeTransferFrom(_msgSender(), address(this), tokenId);

      payable(this).transfer(listingFee);

      feeTotals = feeTotals.add(listingFee);

      _itemsHeld.increment();
      _itemsTotal.increment();
      
      emit MarketItemCreated(
        _msgSender(),
        tokenId,
        price,
        block.timestamp
      );
    }

    /* allows someone to remove a token they have listed */
    function removeMarketItem(uint256 tokenId) external nonReentrant {

      require(idToMarketItem[tokenId].seller == address(_msgSender()) || owner() == address(_msgSender()), "Only item seller can perform this operation");
      
      idToMarketItem[tokenId].sold = false;
      idToMarketItem[tokenId].price = 0;
      idToMarketItem[tokenId].seller = payable(address(0));
      idToMarketItem[tokenId].owner = payable(address(0));
      idToMarketItem[tokenId].nftid = 0;    
      idToMarketItem[tokenId].pack = 0;

      _itemsHeld.decrement();

      for(uint x=0; x<heldtokens.length; x++) {                                     
        if(heldtokens[x] == tokenId) {
            heldtokens[x] = heldtokens[heldtokens.length-1];
            heldtokens.pop();
        }
      }

      IERC721(directory.getNFT()).safeTransferFrom(address(this), _msgSender(), tokenId);
    }

    /* Creates the sale of a marketplace item */
    /* Transfers ownership of the item, as well as funds between parties */
    function createMarketSale(
      uint256 tokenId
      ) external payable nonReentrant {
      uint price = idToMarketItem[tokenId].price;
      address seller = idToMarketItem[tokenId].seller;
      require(msg.value == price.add(buyingFee), "Please submit the asking price + fee in order to complete the purchase");

      idToMarketItem[tokenId].owner = payable(_msgSender());
      idToMarketItem[tokenId].sold = true;
      idToMarketItem[tokenId].seller = payable(seller);

      _itemsHeld.decrement();
      _itemsSold.increment();

      IERC721(directory.getNFT()).safeTransferFrom(address(this), _msgSender(), tokenId);
      payable(this).transfer(buyingFee);
      feeTotals = feeTotals.add(buyingFee);
      payable(seller).transfer(msg.value.sub(buyingFee));

      for(uint x=0; x<heldtokens.length; x++) {                                     
        if(heldtokens[x] == tokenId) {
            heldtokens[x] = heldtokens[heldtokens.length-1];
            heldtokens.pop();
        }
      }

      soldtokens.push(tokenId);

      emit MarketItemSold(
        seller,
        _msgSender(),
        tokenId,
        price,
        true,
        block.timestamp
      );
    }

    /* Returns all unsold market items */
    function fetchMarketItems(uint _pack, uint _nftid) public view returns (MarketItem[] memory) {

      uint itemCount = _itemsHeld.current();

      if(itemCount > 0) {

        uint currentIndex = 0;

        MarketItem[] memory items = new MarketItem[](itemCount);

        if(_pack == 99 && _nftid == 0) { //get all

            for (uint i = 0; i < itemCount; i++) {
                if (idToMarketItem[heldtokens[i]].owner == address(this)) {
                items[currentIndex] = idToMarketItem[heldtokens[i]];
                currentIndex++;
                }
            }
            return items;

        } else {

            if(_pack != 99 && _nftid == 0) { //get all from pack

                for (uint i = 0; i < itemCount; i++) {
                    if (idToMarketItem[heldtokens[i]].owner == address(this) 
                    && idToMarketItem[heldtokens[i]].pack == _pack) {
                    items[currentIndex] = idToMarketItem[heldtokens[i]];
                    currentIndex++;
                    }
                }
                return items;

            } else {

                for (uint i = 0; i < itemCount; i++) { //get pack and single nft
                    if (idToMarketItem[heldtokens[i]].owner == address(this) 
                    && idToMarketItem[heldtokens[i]].pack == _pack
                    && idToMarketItem[heldtokens[i]].nftid == _nftid) {
                    items[currentIndex] = idToMarketItem[heldtokens[i]];
                    currentIndex++;
                    }
                }
                return items;
            }
        }
        
      } else {
        return new MarketItem[](0);
      }       
    }

    /* Returns only items that a user has purchased */
    function fetchMyNFTs(address _user) public view returns (MarketItem[] memory) {

      if(soldtokens.length > 0) {
        uint itemCount = 0;
        uint currentIndex = 0;

        for (uint i = 0; i < soldtokens.length; i++) {
            if (idToMarketItem[soldtokens[i]].owner == _user) {
            itemCount++;
            }
        }

        MarketItem[] memory items = new MarketItem[](itemCount);
        for (uint i = 0; i < soldtokens.length; i++) {
            if (idToMarketItem[soldtokens[i]].owner == _user) {
            items[currentIndex] = idToMarketItem[soldtokens[i]];
            currentIndex++;
            }
        }
        return items;

      } else {
        return new MarketItem[](0);
      }
    }

    /* Returns only items a user has listed */
    function fetchItemsListed(address _seller) public view returns (MarketItem[] memory) {
      uint totalItemCount = _itemsHeld.current();

      if(totalItemCount > 0) {
            uint itemCount = 0;
            uint currentIndex = 0;

        for (uint i = 0; i < totalItemCount; i++) {
            if (idToMarketItem[heldtokens[i]].seller == _seller) {
            itemCount++;
            }
        }

        MarketItem[] memory items = new MarketItem[](itemCount);
        for (uint i = 0; i < totalItemCount; i++) {
            if (idToMarketItem[heldtokens[i]].seller == _seller) {
            items[currentIndex] = idToMarketItem[heldtokens[i]];
            currentIndex++;
            }
        }
        
        return items;

      } else {
        return new MarketItem[](0);
      }
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

    function setProduction(bool _status) external onlyOwner {
      production = _status;
    }

    function changeDirectory(address _directory) external onlyAuthorized {
        directory = IDirectory(_directory);
    }
}
