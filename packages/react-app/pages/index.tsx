import { Contract } from 'web3-eth-contract';
import { useCelo } from "@celo/react-celo";
import Web3 from 'web3';
import React, { useState } from 'react';

// Import the MultiTierStakingContract ABI and address
import MultiTierStakingContract from '../../hardhat/deployments/alfajores/MultiTierStaking.json';

// Instantiate Web3 with the provided provider
const web3 = new Web3(Web3.givenProvider);

function App(): JSX.Element {
  const [account, setAccount] = useState<string>('');
  const [balance, setBalance] = useState<string>('');
  const [stakeAmount, setStakeAmount] = useState<string>('');
  const [stakingTxHash, setStakingTxHash] = useState<string>('');
  const [rewardTxHash, setRewardTxHash] = useState<string>('');

  // Define the account info interface
  interface AccountInfo {
    account: string;
    balance: string;
  }

  // Set the contract address
  const contractAddress = '0x6DF5370EC8558D3F89B391c48b8815De4b1FACA4';

  // Instantiate the MultiTierStakingContract with the contract ABI and address
  const contract = new web3.eth.Contract(
    [
      {
        "anonymous": false,
        "inputs": [
          {
            "indexed": true,
            "internalType": "address",
            "name": "staker",
            "type": "address"
          },
          {
            "indexed": false,
            "internalType": "uint256",
            "name": "amount",
            "type": "uint256"
          }
        ],
        "name": "RewardsClaimed",
        "type": "event"
      },
      {
        "anonymous": false,
        "inputs": [
          {
            "indexed": true,
            "internalType": "address",
            "name": "staker",
            "type": "address"
          },
          {
            "indexed": false,
            "internalType": "uint256",
            "name": "amount",
            "type": "uint256"
          }
        ],
        "name": "Staked",
        "type": "event"
      },
      {
        "anonymous": false,
        "inputs": [
          {
            "indexed": true,
            "internalType": "address",
            "name": "staker",
            "type": "address"
          },
          {
            "indexed": false,
            "internalType": "uint256",
            "name": "amount",
            "type": "uint256"
          }
        ],
        "name": "Unstaked",
        "type": "event"
      },
      {
        "inputs": [
          {
            "internalType": "address",
            "name": "",
            "type": "address"
          }
        ],
        "name": "balances",
        "outputs": [
          {
            "internalType": "uint256",
            "name": "",
            "type": "uint256"
          }
        ],
        "stateMutability": "view",
        "type": "function"
      },
      {
        "inputs": [],
        "name": "claimRewards",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function"
      },
      {
        "inputs": [],
        "name": "extendStakeDuration",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function"
      },
      {
        "inputs": [],
        "name": "maximumStakeDuration",
        "outputs": [
          {
            "internalType": "uint256",
            "name": "",
            "type": "uint256"
          }
        ],
        "stateMutability": "view",
        "type": "function"
      },
      {
        "inputs": [],
        "name": "minimumStake",
        "outputs": [
          {
            "internalType": "uint256",
            "name": "",
            "type": "uint256"
          }
        ],
        "stateMutability": "view",
        "type": "function"
      },
      {
        "inputs": [],
        "name": "minimumStakeTime",
        "outputs": [
          {
            "internalType": "uint256",
            "name": "",
            "type": "uint256"
          }
        ],
        "stateMutability": "view",
        "type": "function"
      },
      {
        "inputs": [],
        "name": "rewardRate",
        "outputs": [
          {
            "internalType": "uint256",
            "name": "",
            "type": "uint256"
          }
        ],
        "stateMutability": "view",
        "type": "function"
      },
      {
        "inputs": [
          {
            "internalType": "uint256",
            "name": "_rewardRate",
            "type": "uint256"
          }
        ],
        "name": "setRewardRate",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function"
      },
      {
        "inputs": [
          {
            "internalType": "uint256[]",
            "name": "amounts",
            "type": "uint256[]"
          }
        ],
        "name": "splitStake",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function"
      },
      {
        "inputs": [],
        "name": "stake",
        "outputs": [],
        "stateMutability": "payable",
        "type": "function"
      },
      {
        "inputs": [
          {
            "internalType": "address",
            "name": "",
            "type": "address"
          }
        ],
        "name": "timeStaked",
        "outputs": [
          {
            "internalType": "uint256",
            "name": "",
            "type": "uint256"
          }
        ],
        "stateMutability": "view",
        "type": "function"
      },
      {
        "inputs": [
          {
            "internalType": "address",
            "name": "",
            "type": "address"
          }
        ],
        "name": "totalRewards",
        "outputs": [
          {
            "internalType": "uint256",
            "name": "",
            "type": "uint256"
          }
        ],
        "stateMutability": "view",
        "type": "function"
      },
      {
        "inputs": [],
        "name": "unstake",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function"
      }
    ],

  );

  // Function to get the account info (account address and balance)
  const getAccountInfo = async (): Promise<void> => {
    try {
      const accounts = await web3.eth.getAccounts();
      if (accounts.length > 0) {
        setAccount(accounts[0]);
        const accountBalance = await web3.eth.getBalance(accounts[0]);
        const balanceInEth = web3.utils.fromWei(accountBalance, 'ether');
        setBalance(balanceInEth);
      } else {
        console.error('No accounts found!');
      }
    } catch (error) {
      console.error(error);
    }
  };
  

  const getAccountBalance = async (account: string): Promise<void> => {
    const accountBalance = await web3.eth.getBalance(account);
    const balanceInEth = web3.utils.fromWei(accountBalance, 'ether');
    setBalance(balanceInEth);
  };
  

  // Function to handle staking
  const handleStake = async (): Promise<void> => {
    const weiAmount = web3.utils.toWei(stakeAmount, 'ether');
    if (contract.options.address) {
      const tx = await contract.methods.stake().send({ value: weiAmount, from: account });
      setStakingTxHash(tx.transactionHash);
    } else {
      console.error('Contract address is not set!');
    }
  };
  

  // Function to handle claiming rewards
  const handleClaimRewards = async (): Promise<void> => {
    if (!account) {
      console.error('Account is not defined.');
      return;
    }

    try {
      const tx = await contract.methods.claimRewards().send({ from: account });
      setRewardTxHash(tx.transactionHash);
    } catch (error) {
      console.error(error);
    }
  };

  
    return (
      <div style={{ backgroundColor: "#F9F9F9", padding: "20px", borderRadius: "5px" }}>
        <h1 style={{ textAlign: "center", marginBottom: "20px" }}>Multi-Tier Staking DApp</h1>
        <div>
  <p>Account Address: {account}</p>
  <p>Account Balance: {balance} CELO</p>
  <button onClick={getAccountInfo} style={{ backgroundColor: '#4CAF50', color: 'white', padding: '10px', borderRadius: '3px', border: 'none', cursor: 'pointer' }}>Refresh Account Info</button>
</div>

        <div style={{ marginTop: "20px" }}>
          <h2>Stake</h2>
          <input type="text" value={stakeAmount} onChange={(e) => setStakeAmount(e.target.value)} style={{ padding: "5px", marginRight: "10px", borderRadius: "3px" }} />
          <button onClick={handleStake} style={{ backgroundColor: "#4CAF50", color: "white", border: "none", padding: "10px 20px", borderRadius: "3px" }}>Stake</button>
        </div>
      </div>
    );
  }
  
  


export default App;
