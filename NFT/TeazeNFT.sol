//Contract based on https://docs.openzeppelin.com/contracts/3.x/erc721
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

//To Do: provide function that removes collections 
//Removing a collection needs to accomplish the following:
//-remove collection in struct (is re-arrangement necessary?)
//-set all NFT assigned to that collection to unassigned
//-set collection[name] to false

//Update functions to edit packs/nfts
//Provide interface for marketplace/lootbox contract to interact with


// Allows another user(s) to change contract variables
contract Authorizable is Ownable {

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

// Allows authorized users to add creators/infuencer addresses to the whitelist
contract Whitelisted is Ownable, Authorizable {

    mapping(address => bool) public whitelisted;

    modifier onlyWhitelisted() {
        require(whitelisted[_msgSender()] || authorized[_msgSender()]);
        _;
    }

    function addWhitelisted(address _toAdd) onlyAuthorized public {
        require(_toAdd != address(0));
        whitelisted[_toAdd] = true;
    }

    function removeWhitelisted(address _toRemove) onlyAuthorized public {
        require(_toRemove != address(0));
        require(_toRemove != address(_msgSender()));
        whitelisted[_toRemove] = false;
    }

}

abstract contract TeazeNFT is Ownable, Authorizable, Whitelisted, ERC721Enumerable, ReentrancyGuard  {
    using Counters for Counters.Counter;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    Counters.Counter private _tokenIds;
    Counters.Counter private _PackIds; //so we can track which Packs have been added to the system
    Counters.Counter private _NFTIds; //so we can track which NFT's have been added to the Packs

    struct PackInfo {
        address creatorAddress; //wallet address of the NFT creator/infuencer
        string collectionName; // Name of nft creator/influencer/artist
        uint256 packID; //ID of the pack
        uint256 price; //BNB minting price of the NFT Pack
        uint256 priceStep; //how much the price of the NFT should increase in BNB
        uint256 sbxprice; //SimpBux price of minting from the NFT Pack
        uint256 creatorSplit; //percent to split proceeds with creator/pool;
        uint256 mintLimit; //total amount of this NFT to mint
        bool redeemable; //can be purchased with SimpBux
        bool purchasable; //can be purchased with BNB tokens
        bool exists;
    }

    struct NFTInfo {
        string nftName; // Name of the actual NFT artwork
        string uri; //address of NFT metadata
        uint256 packID; //ID of the 3 card pack
        uint256 mintClass; //0 = common, 1 = uncommon, 2 = rare
        uint256 mintPercent; //percent chance out of 100 for the NFT to mint
        bool lootboxable; //can be added to lootbox
        bool exists;
    }

    mapping (string => bool) private collections; //Whether the collection name exists or not.
    mapping (uint => bool) private packs; //Whether the packID exists or not.
    mapping(uint256 => PackInfo) public packInfo; // Info of each NFT artist/infuencer wallet.
    mapping(uint256 => NFTInfo) public nftInfo; // Info of each NFT artist/infuencer wallet.
    mapping(uint => uint256[]) private PackIDS; // array of NFT ID's listed under each pack.
    mapping(uint => uint256) private PackNFTmints; //number of NFT minted from a certain pack.
    mapping(string => uint) private NFTmintedCountURI;  // Get total # minted by URI.
    mapping(string => bool) private NFTuriExists;  // Get total # minted by URI.
    mapping(uint256 => uint) private NFTmintedCountID; // Get total # minted by NFTID.
    mapping(address => mapping(uint => uint)) private userPackPurchased; //How many of each pack a certain address has minted.

    address public farmingContract; // Address of the associated farming contract.
    uint private minted;

    constructor() ERC721("CryptezeNFT", "TeazeNFT") {}

    receive() external payable {}

    function mint(address _recipient, uint256 _packid, bool _method) public nonReentrant returns (uint256) {

        //method: false = BNB purchase, true = redeem with SBX

        require(address(farmingContract) != address(0), "Farming contract address is invalid");
        require(msg.sender == address(farmingContract), "Minting not allowed outside of the farming contract");

        PackInfo storage packinfo = packInfo[_packid];

        require(PackNFTmints[_packid] < packinfo.mintLimit, "This NFT Pack has reached its mint limit");

        //Randomizing mint starts here
        uint packlength = PackIDS[_packid].length;

        require(packlength >= 3, "Not enough NFTs in this pack to mint from");

        uint256 roll = uint256(block.blockhash(block.number-1)) % 100; //get user roll 0-99
        
        uint256[] memory array = new uint256[](100); //create array from 0-99

        for (uint256 x = 0; x < packlength; ++x) { //for each NFTID in the pack

            NFTInfo memory tempnftinfo = nftInfo[PackIDS[_packid][x]]; //should be NFT info of each nft in for loop

            for(uint256 y = 0; y < tempnftinfo.mintPercent; y++) {
                array[y] = PackIDS[_packid][x]; //populate array with # of percentage (ex. 59%, put 59 entries in the array)
            }

        }

        for (uint256 i = 0; i < array.length; i++) { //now we take our array and scramble the contents
            uint256 n = i + uint256(keccak256(abi.encodePacked(block.timestamp))) % (array.length - i);
            uint256 temp = array[n];
            array[n] = array[i];
            array[i] = temp;
        }

        uint256 nftid = array[roll];
        NFTInfo storage nftinfo = nftInfo[nftid];
        
        _tokenIds.increment();
        
        uint256 newItemId = _tokenIds.current();
        _mint(_recipient, newItemId);
        _setTokenURI(newItemId,nftinfo.uri);

        //update counters

        if(!_method) { //user paid in BNB, record so next purchase increases in price

        userPackPurchased[_recipient][_packid] = userPackPurchased[_recipient][_packid] + 1;
            
        }

        NFTmintedCountURI[nftinfo.uri] = NFTmintedCountURI[nftinfo.uri] + 1;

        NFTmintedCountID[nftid] = NFTmintedCountID[nftid] + 1;

        PackNFTmints[_packid] = PackNFTmints[_packid] + 1;

        return newItemId;

    }

    //returns the total number of minted NFT
    function totalMinted() public view returns (uint256) {
        return _tokenIds.current();
    }

    //returns the balance of the erc20 token required for validation
    function checkBalance(address _token, address _holder) public view returns (uint256) {
        IERC20 token = IERC20(_token);
        return token.balanceOf(_holder);
    }
    //returns the number of mints for each specific NFT based on URI
    function mintedCountbyURI(string memory tokenURI) public view returns (uint256) {
        return NFTmintedCountURI[tokenURI];
    }

    function mintedCountbyID(uint256 _id) public view returns (uint256) {
        return NFTmintedCountID[_id];
    }

    function setFarmingContract(address _address) public onlyAuthorized {
        farmingContract = _address;
    }

    function getFarmingContract() external view returns (address) {
        return farmingContract;
    }

    function setPackInfo (address _creator, string memory _collectionName, uint256 _packID, uint256 _price, uint256 _sbxprice, uint256 _priceStep, uint256 _splitPercent, uint256 _mintLimit,  bool _redeemable, bool _purchasable) public onlyWhitelisted returns (uint256) {
        require(whitelisted[_msgSender()], "Sender is not whitelisted"); 
        require(bytes(_collectionName).length > 0, "Collection name string must not be empty");
        require(!collections[_collectionName], "A pack or collection already exists under that name");
        require(_packID >= 0, "Pack ID must be greater than or equal to zero");
        require(_price > 0, "BNB price must be greater than zero");
        require(_sbxprice > 0, "SBX price must be greater than zero");
        require(_priceStep >= 0, "Price must be greater than or equal zero");
        require(_mintLimit > 0, "Mint limit must be greater than zero");
        require(_splitPercent >= 0 && _splitPercent <= 100, "Split is not between 0 and 100");

        
        _PackIds.increment();

        uint256 _packid = _PackIds.current();

        PackInfo storage packinfo = packInfo[_packid];

        packinfo.creatorAddress = _creator;
        packinfo.collectionName = _collectionName;
        packinfo.packID = _packID;
        packinfo.price = _price;
        packinfo.sbxprice = _sbxprice;
        packinfo.priceStep = _priceStep;
        packinfo.creatorSplit = _splitPercent;
        packinfo.mintLimit = _mintLimit;
        packinfo.redeemable = _redeemable;
        packinfo.purchasable = _purchasable;

        packs[_packid] = true;
        collections[_collectionName] = true;

    }

    
    //NFT's get added to a pack # along with mint class (for the lootbox ordering) and mint percentages (for the user mint chance)
    function setNFTInfo(string memory _nftName, string memory _URI, uint256 _packID, uint256 _mintClass, uint256 _mintPercent, bool _lootboxable) public onlyWhitelisted returns (uint256) {

        require(bytes(_nftName).length > 0, "NFT name string must not be empty");
        require(bytes(_URI).length > 0, "URI string must not be empty");
        require(packs[_packID], "Pack does not exist");
        require(_mintClass >= 0, "mint class must be an integer equal to or greater than zero");
        require(_mintPercent > 0, "mint percent must be an integer greater than zero");
        require(!NFTuriExists[_URI], "An NFT with this URI already exists");

        (,,uint256 percentTotal) = getAllNFTbyPack(_packID);

        require(percentTotal.add(_mintPercent)<=100,"Total mint percent of pack cannot be greater than 100. Are you adding to correct pack?");


        _NFTIds.increment();

        uint256 _nftid = _NFTIds.current();

        NFTInfo storage nftinfo = nftInfo[_nftid];

           nftinfo.nftName = _nftName;  
           nftinfo.uri = _URI;
           nftinfo.packID = _packID;
           nftinfo.mintClass = _mintClass;
           nftinfo.mintPercent = _mintPercent;
           nftinfo.lootboxable = _lootboxable;
           nftinfo.exists = true;

            NFTuriExists[_URI] = true;

            //nftName, uri, packID, mintClass, mintPercent, 

            //To Do: if this NFT is inserted into the wrong pack, provide function that deletes from current pack and adds to correct pack

            PackIDS[_packID].push(_nftid);

        return  _nftid; 

    }

    // Get the current NFT counter
    function getCurrentNFTID() public view returns (uint256) {
        return _NFTIds.current();
    }

    // Get all NFT IDs added to a pack, and return the mint percentage total
    function getAllNFTbyPack(uint256 _packID) public view returns (uint256[] memory, string[] memory, uint256) {
        uint256 totalNFT = _NFTIds.current();
        uint256[] memory ids = new uint256[](totalNFT);
        string[] memory name = new string[](totalNFT);
        uint256 count = 0;
        uint256 percentTotal = 0;

        for (uint256 x = 0; x < totalNFT; ++x) {

            NFTInfo storage nftinfo = nftInfo[x];

            if (nftinfo.packID == _packID) {
                count = count.add(1);
                ids[count] = x;
                name[count] =nftinfo.nftName;
                percentTotal = percentTotal.add(nftinfo.mintPercent);
            }

        }

        return (ids,name,percentTotal);
    }
    
    //Returns the name of all packs or collections
    function getAllCollectionNames() public view returns (uint256[] memory, string[] memory) {

        uint256 totalPacks = _PackIds.current();
        uint256[] memory ids = new uint256[](totalPacks);
        string[] memory name = new string[](totalPacks);
        uint256 count = 0;

        for (uint256 x = 0; x < totalPacks; ++x) {

            PackInfo storage packinfo = packInfo[x];

            if (bytes(packinfo.collectionName).length > 0) {
                count = count.add(1);
                ids[count] = x;
                name[count] = packinfo.collectionName;
            }

        }

        return (ids,name);
    }

    
    // Set creator address to new, or set to 0 address to clear out the NFT completely
    function setCreatorAddress(uint256 _nftid, address _address) public onlyAuthorized {

        NFTInfo storage nftinfo = nftInfo[_nftid];

        require(nftinfo.creatorAddress == address(_msgSender()) || authorized[_msgSender()], "Sender is not creator or authorized");  

        if (_address == address(0)) {

            _NFTIds.decrement();

            NFTuriExists[nftinfo.uri] = false;

           nftinfo.creatorAddress = _address;
           nftinfo.collectionName = "";
           nftinfo.nftName = "";
           nftinfo.uri = "";
           nftinfo.price = 0;
           nftinfo.creatorSplit = 0;
           nftinfo.mintLimit = 0;
           nftinfo.redeemable = false;
           nftinfo.purchasable = false;
           nftinfo.exists = false;

        } else {

           nftinfo.creatorAddress = _address;
        }
    }

    // Get NFT creator/influence/artist info
    function getNFTInfo(uint256 _nftid) external view returns (address,string memory,string memory,string memory,uint256,uint256,uint256,bool,bool,bool) {
        NFTInfo storage nftinfo = nftInfo[_nftid];
        return (nftinfo.creatorAddress,nftinfo.collectionName,nftinfo.nftName,nftinfo.uri,nftinfo.price,nftinfo.creatorSplit,nftinfo.mintLimit,nftinfo.redeemable,nftinfo.purchasable,nftinfo.exists);
    }

    // Get NFT influencer/artist/creator address
    function getCreatorAddress(uint256 _nftid) external view returns (address) {
        NFTInfo storage nftinfo = nftInfo[_nftid];
        return nftinfo.creatorAddress;
    }

    // Get NFT URI string
    function getCreatorURI(uint256 _nftid) external view returns (string memory) {
        NFTInfo storage nftinfo = nftInfo[_nftid];
        return nftinfo.uri;
    }

    // Set NFT creator name
    function setNFTcollectionName(uint256 _nftid, string memory _name) public onlyAuthorized {

        NFTInfo storage nftinfo = nftInfo[_nftid];

        require(nftinfo.creatorAddress == address(_msgSender()) || authorized[_msgSender()], "Sender is not creator or authorized");   
        require(bytes(_name).length > 0, "Creator name string must not be empty");    

       nftinfo.collectionName = _name;
    }

    // Set NFT name
    function setNFTname(uint256 _nftid, string memory _name) public onlyAuthorized {

        NFTInfo storage nftinfo = nftInfo[_nftid];

        require(nftinfo.creatorAddress == address(_msgSender()) || authorized[_msgSender()], "Sender is not creator or authorized");   
        require(bytes(_name).length > 0, "NFT name string must not be empty");     

       nftinfo.nftName = _name;
    }

    // Set NFT URI string
    function setNFTUri(uint256 _nftid, string memory _uri) public onlyAuthorized {

        NFTInfo storage nftinfo = nftInfo[_nftid];

        require(nftinfo.creatorAddress == address(_msgSender()) || authorized[_msgSender()], "Sender is not creator or authorized");  
        require(bytes(_uri).length > 0, "URI string must not be empty");     
        require(!NFTuriExists[_uri], "An NFT with this URI already exists"); 

        NFTuriExists[nftinfo.uri] = false;

       nftinfo.uri = _uri;

        NFTuriExists[_uri] = true;
    }

     // Set cost of NFT
    function setNFTCost(uint256 _nftid, uint256 _cost) public onlyAuthorized {

        NFTInfo storage nftinfo = nftInfo[_nftid];

        require(nftinfo.creatorAddress == address(_msgSender()) || authorized[_msgSender()], "Sender is not creator or authorized");  
        require(_cost > 0, "Price must be greater than zero");

       nftinfo.price = _cost;
    }

    // Get cost of NFT
    function getCreatorPrice(uint256 _nftid) external view returns (uint256) {
        NFTInfo storage nftinfo = nftInfo[_nftid];
        return nftinfo.price;
    }

    // Get cost of NFT in staking currency
    function getCreatorSimpBuxPrice(uint256 _nftid) external view returns (uint256) {
        NFTInfo storage nftinfo = nftInfo[_nftid];
        return nftinfo.sbxprice;
    }

    // Set profit sharing of NFT
    function setNFTSplit(uint256 _nftid, uint256 _split) public onlyAuthorized {

        NFTInfo storage nftinfo = nftInfo[_nftid];

        require(nftinfo.creatorAddress == address(_msgSender()) || authorized[_msgSender()], "Sender is not creator or authorized");  
        require(_split >= 0 && _split <= 100, "Split is not between 0 and 100");

       nftinfo.creatorSplit = _split;
    }

    function getCreatorSplit(uint256 _nftid) external view returns (uint256) {
        NFTInfo storage nftinfo = nftInfo[_nftid];
        return nftinfo.creatorSplit;
    }

    // Set NFT mint limit
    function setNFTmintLimit(uint256 _nftid, uint256 _limit) public onlyAuthorized {

        NFTInfo storage nftinfo = nftInfo[_nftid];

        require(nftinfo.creatorAddress == address(_msgSender()) || authorized[_msgSender()], "Sender is not creator or authorized"); 
        require(_limit > 0, "Mint limit must be greater than zero");

       nftinfo.mintLimit = _limit;
    }

    function getCreatorMintLimit(uint256 _nftid) external view returns (uint256) {
        NFTInfo storage nftinfo = nftInfo[_nftid];
        return nftinfo.mintLimit;
    }

    // Set NFT redeemable with SimpBux
    function setNFTredeemable(uint256 _nftid, bool _redeemable) public onlyAuthorized {

        NFTInfo storage nftinfo = nftInfo[_nftid];

        require(nftinfo.creatorAddress == address(_msgSender()) || authorized[_msgSender()], "Sender is not creator or authorized"); 

       nftinfo.redeemable = _redeemable;
    }

    

    // Set NFT purchasable with Teaze tokens
    function setNFTpurchasable(uint256 _nftid, bool _purchasable) public onlyAuthorized {

        NFTInfo storage nftinfo = nftInfo[_nftid];

        require(nftinfo.creatorAddress == address(_msgSender()) || authorized[_msgSender()], "Sender is not creator or authorized"); 

       nftinfo.redeemable = _purchasable;
    }

    function getCreatorPurchasable(uint256 _nftid) external view returns (bool) {
        NFTInfo storage nftinfo = nftInfo[_nftid];
        return nftinfo.purchasable;
    }

    function getCreatorExists(uint256 _nftid) external view returns (bool) {
        NFTInfo storage nftinfo = nftInfo[_nftid];
        return nftinfo.exists;
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

    function getIDbyURI(string memory _uri) public view returns (uint256) {
        uint256 totalNFT = _NFTIds.current();
        uint256 nftID = 0;

        for (uint256 x = 1; x <= totalNFT; ++x) {

            NFTInfo storage nftinfo = nftInfo[x];

            if (keccak256(bytes(nftinfo.uri)) == keccak256(bytes(_uri))) {   
                nftID = x;
            }

        }

        return nftID;
    }

    function getPackIDbyNFT(uint256 _nftid) external returns (uint256) {

        NFTInfo storage nftinfo = nftInfo[_nftid];
        return nftinfo.packID;

    }

    function packPurchased(address _recipient, uint256 _packid) external {

        require(msg.sender == address(farmingContract), "Function call not allowed outside of the farming contract");

        PackInfo storage packinfo = packInfo[_packid];

       packinfo.price = packinfo.price.add(packinfo.priceStep);

    }

    function getPackPrice(uint256 _packid) public returns (uint256) {
        PackInfo storage packinfo = packInfo[_packid];

        return packinfo.price;
    }

    function getPackPriceStep(uint256 _packid) public returns (uint256) {
        PackInfo storage packinfo = packInfo[_packid];

        return packinfo.priceStep;
    }

    function getPackRedeemable(uint256 _packid) external view returns (bool) {
        PackInfo storage packinfo = packInfo[_packid];
        return packinfo.redeemable;
    }

    function getPackPurchasable(uint256 _packid) external view returns (bool) {
        PackInfo storage packinfo = packInfo[_packid];
        return packinfo.purchasable;
    }

    function getPackMintLimit(uint256 _packid) external view returns (uint256) {
        PackInfo storage packinfo = packInfo[_packid];
        return packinfo.mintLimit;
    }

    function getPackTotalMints(uint256 _packid) external view returns (uint256) {
        return PackNFTmints[_packid];
    }

    function getUserPackPurchased(address _recipient, uint256 _packid) public view returns (uint256) {
        return userPackPurchased[_recipient][_packid];
    }

    function getUserPackPrice(address _recipient, uint256 _packid) external view returns (uint256) {

        uint256 purchases = getUserPackPurchased(_recipient, _packid);
        uint256 price = getPackPrice(_packid);
        uint256 priceStep = getPackPriceStep(_packid);
             
        uint256 userPrice = price.add(purchases.mul(priceStep));

        return userPrice;
    }
}

