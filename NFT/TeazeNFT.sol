//Contract based on https://docs.openzeppelin.com/contracts/3.x/erc721
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";


interface ITeazePacks {
    function getPackInfo(uint256 _packid) external view returns (uint256,uint256,uint256,uint256,bool,bool); 
    function getPackTotalMints(uint256 _packid) external view returns (uint256); 
    function getNFTURI(uint256 _nftid) external view returns (string memory);
    function getPackIDbyNFT(uint256 _nftid) external view returns (uint256);
}

interface Directory {
    function getPacks() external view returns (address);
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

contract TeazeNFT is Ownable, Authorized, ERC721URIStorage, ERC721Enumerable, ReentrancyGuard {
    using Counters for Counters.Counter;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    Counters.Counter public _tokenIds;
       
    mapping(string => uint) private NFTmintedCountURI;  // Get total # minted by URI.
    mapping(string => bool) private NFTuriExists;  // Get total # minted by URI.
    mapping(uint256 => uint) private NFTmintedCountID; // Get total # minted by NFTID.
   
    Directory public directory;
    uint private minted;
    

    constructor(address _directory) ERC721("CryptezeNFT", "TeazeNFT") {
        addAuthorized(owner());
        directory = Directory(_directory);
    }

    receive() external payable {}

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function tokenURI(uint256 tokenId) public view virtual override(ERC721, ERC721URIStorage) returns (string memory) {
        return ERC721URIStorage.tokenURI(tokenId);
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId) internal virtual override(ERC721, ERC721Enumerable) {
        super._beforeTokenTransfer(from, to, tokenId);
    }

    function _burn(uint256 tokenId) internal virtual override(ERC721, ERC721URIStorage) {
        return ERC721URIStorage._burn(tokenId);
    }
    

    function mint(address _recipient, string memory _uri, uint _packNFTid) public nonReentrant returns (uint256) {

        require(address(directory.getPacks()) != address(0), "Packs contract address is invalid");
        require(msg.sender == address(directory.getPacks()), "Minting not allowed outside of the Packs contract");

        _tokenIds.increment();
        
        uint256 newItemId = _tokenIds.current();
        _mint(_recipient, newItemId);
        _setTokenURI(newItemId, _uri);

        NFTmintedCountURI[_uri] = NFTmintedCountURI[_uri] + 1;

        NFTmintedCountID[_packNFTid] = NFTmintedCountID[_packNFTid] + 1;

        return newItemId;

    }

    function adminMint(uint256 _nftid) public onlyAuthorized nonReentrant returns (uint256) {

        require(address(directory.getPacks()) != address(0), "Packs contract address is invalid");

        _tokenIds.increment();
        string memory _uri = ITeazePacks(directory.getPacks()).getNFTURI(_nftid);
        uint256 _packNFTid = ITeazePacks(directory.getPacks()).getPackIDbyNFT(_nftid);
        
        uint256 newItemId = _tokenIds.current();
        _mint(_msgSender(), newItemId);
        _setTokenURI(newItemId, _uri);

        NFTmintedCountURI[_uri] = NFTmintedCountURI[_uri] + 1;

        NFTmintedCountID[_packNFTid] = NFTmintedCountID[_packNFTid] + 1;

        return newItemId;

    }

    //returns the balance of the erc20 token required for validation
    function checkBalance(address _token, address _holder) public view returns (uint256) {
        IERC20 token = IERC20(_token);
        return token.balanceOf(_holder);
    }
    //returns the number of mints for each specific NFT based on URI
    function mintedCountbyURI(string memory _tokenURI) public view returns (uint256) {
        return NFTmintedCountURI[_tokenURI];
    }

    function mintedCountbyID(uint256 _id) public view returns (uint256) {
        return NFTmintedCountID[_id];
    }

    function rescueETHFromContract() external onlyOwner {
        address payable _owner = payable(_msgSender());
        _owner.transfer(address(this).balance);
    }

    function transferERC20Tokens(address _tokenAddr, address _to, uint _amount) external onlyOwner {
       
        IERC20(_tokenAddr).transfer(_to, _amount);
    }

    function changeDirectory(address _directory) external onlyAuthorized {
        directory = Directory(_directory);
    }

}

