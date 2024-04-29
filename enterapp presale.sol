// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint reserve0, uint reserve1, uint32 blockTimestampLast);
}

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
}

abstract contract Ownable is Context {
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    constructor() {
        _transferOwnership(_msgSender());
    }
    function owner() public view virtual returns (address) {
        return _owner;
    }
    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _transferOwnership(newOwner);
    }
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

contract PresaleContract is Ownable {
    IUniswapV2Pair public uniswapPair;
    IERC20 public presaleToken;
    IERC20 public usdtToken;
    IERC20 public usdcToken;
    bool public presaleEnded = false;
    uint256 public nextRoundId = 1;
    uint256 public nextPurchaseId = 1;
    struct PresaleRound {
        uint256 startBlock;
        uint256 endBlock;
        uint256 swapRateInUSD;
        uint256[] tokenLockupPeriods;
        uint256 maxAmountPerUser;
        uint256 minAmountPerUser;
        bool status; // Indicates if the presale round is active
    }
    struct TokenPurchase {
        uint256 tokensPurchased;
        uint256 purchaseBlock;
        uint256 purchaseId;
    }
    struct ReleaseSchedule {
        uint256 totalReleases;
        uint256 tokensPerRelease;
        uint256[] releaseBlocks; // Array to store the block numbers for releases
    }
    mapping(uint256 => PresaleRound) public presaleRounds;
    mapping(address => TokenPurchase[]) public purchasesByUser;
    mapping(address => mapping(uint256 => ReleaseSchedule)) private releaseSchedulesByPurchase;
    mapping(address => mapping(uint256 => uint256[])) private releaseBlocksByPurchase;
    event Purchase(address indexed buyer, uint256 indexed purchaseId, uint256 tokensPurchased, uint256 purchaseBlock);
    event PresaleRoundAdded(uint256 indexed roundId);
    event PresaleRoundUpdated(uint256 indexed roundId, bool status);

    constructor(address _presaleToken, address _usdtToken, address _usdcToken, address _uniswapPair) {
        presaleToken = IERC20(_presaleToken);
        usdtToken = IERC20(_usdtToken);
        usdcToken = IERC20(_usdcToken);
        uniswapPair = IUniswapV2Pair(_uniswapPair);
    }
    function addPresaleRound(uint256 startBlock, uint256 endBlock, uint256 swapRateInUSD, uint256[] memory tokenLockupPeriods, uint256 maxAmountPerUser, uint256 minAmountPerUser, bool status) external onlyOwner {
        presaleRounds[nextRoundId] = PresaleRound({
            startBlock: startBlock,
            endBlock: endBlock,
            swapRateInUSD: swapRateInUSD,
            tokenLockupPeriods: tokenLockupPeriods,
            maxAmountPerUser: maxAmountPerUser,
            minAmountPerUser: minAmountPerUser,
            status: status
        });
        emit PresaleRoundAdded(nextRoundId);
        nextRoundId++;
    }
    function updatePresaleRound(uint256 roundId, uint256 startBlock, uint256 endBlock, uint256 swapRateInUSD, uint256[] memory tokenLockupPeriods, uint256 maxAmountPerUser, uint256 minAmountPerUser, bool status) external onlyOwner {
        require(presaleRounds[roundId].startBlock != 0, "Round does not exist");
        presaleRounds[roundId] = PresaleRound({
            startBlock: startBlock,
            endBlock: endBlock,
            swapRateInUSD: swapRateInUSD,
            tokenLockupPeriods: tokenLockupPeriods,
            maxAmountPerUser: maxAmountPerUser,
            minAmountPerUser: minAmountPerUser,
            status: status
        });
        emit PresaleRoundUpdated(roundId, status);
    }
    function updateUniswapPair(address _newUniswapPair) external onlyOwner {
        uniswapPair = IUniswapV2Pair(_newUniswapPair);
    }
    function ethRate() public view returns (uint256) {
        (uint reserve0, uint reserve1,) = uniswapPair.getReserves();
        require(reserve1 != 0, "Cannot divide by zero");
        uint256 adjustedReserve0 = reserve0 * 1e12; // Scale USDT up to 18 decimals to match ETH
        uint256 rawRate = adjustedReserve0 / reserve1; // This is the rate in wei
        return rawRate / 1e17; // Adjust the rate to a more 'human-readable' format
    }
    function swapWithETH(uint256 roundId) external payable {
        require(!presaleEnded, "Presale has ended");
        require(msg.value > 0, "No ETH sent");
        PresaleRound storage round = presaleRounds[roundId];
        require(round.status, "Round not active");
        require(block.number >= round.startBlock && block.number <= round.endBlock, "Not within round limits");
        uint256 currentEthRate = ethRate(); // Fetch current ETH rate live
        uint256 usdtEquivalent = msg.value * currentEthRate / 1e12; // Calculate USDT equivalent
        require(usdtEquivalent >= round.minAmountPerUser, "Amount below minimum threshold");
        // Checking the maximum amount allowed
        uint256 totalPurchasedThisRound = 0;
        TokenPurchase[] storage userPurchases = purchasesByUser[msg.sender];
        for (uint256 i = 0; i < userPurchases.length; i++) {
            if (userPurchases[i].purchaseBlock >= round.startBlock && userPurchases[i].purchaseBlock <= round.endBlock) {
                totalPurchasedThisRound += userPurchases[i].tokensPurchased;
            }
        }
        require(totalPurchasedThisRound + usdtEquivalent <= round.maxAmountPerUser, "Purchase exceeds max amount per user");
        // Calculate tokens based on swap rate
        uint256 tokensPurchased = usdtEquivalent * round.swapRateInUSD / 1e6;
        require(tokensPurchased + totalPurchasedThisRound <= round.maxAmountPerUser, "Total purchase exceeds max amount per user");
        (bool sent, ) = owner().call{value: msg.value}("");
        require(sent, "Failed to send ETH");
        // Record purchase
        uint256 currentPurchaseId = nextPurchaseId++;
        TokenPurchase memory purchase = TokenPurchase({
            tokensPurchased: tokensPurchased,
            purchaseBlock: block.number,
            purchaseId: currentPurchaseId
        });
        purchasesByUser[msg.sender].push(purchase);
        emit Purchase(msg.sender, currentPurchaseId, tokensPurchased, block.number);
        // Initialize and calculate release schedule
        ReleaseSchedule storage schedule = releaseSchedulesByPurchase[msg.sender][currentPurchaseId];
        schedule.totalReleases = round.tokenLockupPeriods.length;
        schedule.tokensPerRelease = tokensPurchased / schedule.totalReleases;
        schedule.releaseBlocks = new uint256[](round.tokenLockupPeriods.length);
        uint256 releaseBlock = purchase.purchaseBlock;
        for (uint256 i = 0; i < round.tokenLockupPeriods.length; i++) {
            releaseBlock += round.tokenLockupPeriods[i];
            schedule.releaseBlocks[i] = releaseBlock;
        }
    }
    function swapWithUSD(uint256 _amount, address _token, uint256 roundId) external {
        require(!presaleEnded, "Presale has ended");
        require(_amount > 0, "Invalid token amount");
        require(_token == address(usdtToken) || _token == address(usdcToken), "Invalid token used for purchase");
        PresaleRound storage round = presaleRounds[roundId];
        require(round.status, "Round not active");
        require(block.number >= round.startBlock && block.number <= round.endBlock, "Not within round limits");
        require(_amount >= round.minAmountPerUser, "Amount below minimum threshold");
        // Calculate the number of tokens that can be bought with the given amount of stablecoin.
        uint256 tokensPurchased = _amount * round.swapRateInUSD / 1e6;
        uint256 totalPurchasedThisRound = 0;
        TokenPurchase[] storage userPurchases = purchasesByUser[msg.sender];
        for (uint256 i = 0; i < userPurchases.length; i++) {
            if (userPurchases[i].purchaseBlock >= round.startBlock && userPurchases[i].purchaseBlock <= round.endBlock) {
                totalPurchasedThisRound += userPurchases[i].tokensPurchased;
            }
        }
        require(totalPurchasedThisRound + tokensPurchased <= round.maxAmountPerUser, "Total purchase exceeds max amount per user");
        IERC20 token = IERC20(_token);
        require(token.transferFrom(msg.sender, this.owner(), _amount), "Failed to transfer tokens");
        uint256 currentPurchaseId = nextPurchaseId++;
        TokenPurchase memory purchase = TokenPurchase({
            tokensPurchased: tokensPurchased,
            purchaseBlock: block.number,
            purchaseId: currentPurchaseId
        });
        purchasesByUser[msg.sender].push(purchase);
        emit Purchase(msg.sender, currentPurchaseId, tokensPurchased, block.number);   
        // Initialize and calculate the release schedule
        ReleaseSchedule storage schedule = releaseSchedulesByPurchase[msg.sender][currentPurchaseId];
        schedule.totalReleases = round.tokenLockupPeriods.length;
        schedule.tokensPerRelease = tokensPurchased / schedule.totalReleases;
        schedule.releaseBlocks = new uint256[](round.tokenLockupPeriods.length);
        uint256 releaseBlock = purchase.purchaseBlock;
        for (uint256 i = 0; i < round.tokenLockupPeriods.length; i++) {
            releaseBlock += round.tokenLockupPeriods[i]; // Incrementally add the specified lockup period to the last release block
            schedule.releaseBlocks[i] = releaseBlock; // Store the calculated block number for this release
        }
    }
    function getPurchaseIds(address user) external view returns (uint256[] memory) {
        uint256[] memory ids = new uint256[](purchasesByUser[user].length);
        for (uint256 i = 0; i < purchasesByUser[user].length; i++) {
            ids[i] = purchasesByUser[user][i].purchaseId;
        }
        return ids;
    }
    function getReleaseSchedule(address user, uint256 purchaseId) public view returns (uint256 totalReleases, uint256 tokensPerRelease, uint256[] memory releaseBlocks) {
        ReleaseSchedule storage schedule = releaseSchedulesByPurchase[user][purchaseId];
        return (schedule.totalReleases, schedule.tokensPerRelease, schedule.releaseBlocks);
    }
    function claimTokens(uint256 purchaseId) external {
        require(purchasesByUser[msg.sender].length > 0, "No purchases found");
        TokenPurchase storage purchase = purchasesByUser[msg.sender][purchaseId - 1]; // Adjusting index to match purchaseId
        require(purchase.purchaseId == purchaseId, "Purchase ID mismatch");
        // Use getReleaseSchedule to fetch the release details
        (uint256 totalReleases, uint256 tokensPerRelease, uint256[] memory releaseBlocks) = getReleaseSchedule(msg.sender, purchaseId);
        require(totalReleases > 0, "No tokens to release");
        uint256 totalClaimable = 0;
        uint256 releasesClaimed = 0;
        for (uint i = 0; i < releaseBlocks.length; i++) {
            if (block.number >= releaseBlocks[i] && tokensPerRelease > 0) {
                totalClaimable += tokensPerRelease;
                // Set tokens per release to 0 in storage to mark this release as claimed
                releaseSchedulesByPurchase[msg.sender][purchaseId].releaseBlocks[i] = 0;
                releasesClaimed++;
            }
        }
        require(totalClaimable > 0, "No tokens available for claim");
        require(releasesClaimed > 0, "No new releases available for claim");
        require(presaleToken.transfer(msg.sender, totalClaimable), "Failed to transfer tokens");
        releaseSchedulesByPurchase[msg.sender][purchaseId].totalReleases -= releasesClaimed;
    }
    function withdrawETH(address to, uint256 amount) external onlyOwner {
        payable(to).transfer(amount);
    }
    function withdrawUSDT(address to, uint256 amount) external onlyOwner {
        require(usdtToken.transfer(to, amount), "Failed to transfer USDT");
    }
    function withdrawUSDC(address to, uint256 amount) external onlyOwner {
        require(usdcToken.transfer(to, amount), "Failed to transfer USDT");
    }
    function withdrawPresaleToken(address _recipient, uint256 _amount) external onlyOwner {
        require(presaleToken.transfer(_recipient, _amount), "Contract: Failed to transfer Presale Token");
    }
    receive() external payable {}
    fallback() external payable {}
}