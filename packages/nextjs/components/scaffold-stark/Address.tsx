"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { CopyToClipboard } from "react-copy-to-clipboard";
import { Address as AddressType } from "@starknet-react/chains";
import {
  getChecksumAddress,
  validateAndParseAddress,
  validateChecksumAddress,
} from "starknet";
import { devnet } from "@starknet-react/chains";
import {
  CheckCircleIcon,
  DocumentDuplicateIcon,
} from "@heroicons/react/24/outline";
import { useTargetNetwork } from "~~/hooks/scaffold-stark/useTargetNetwork";
import { getBlockExplorerAddressLink } from "~~/utils/scaffold-stark";
import { BlockieAvatar } from "~~/components/scaffold-stark/BlockieAvatar";
import { useScaffoldStarkProfile } from "~~/hooks/scaffold-stark/useScaffoldStarkProfile";

type AddressProps = {
  address?: AddressType;
  disableAddressLink?: boolean;
  format?: "short" | "long";
  size?: "xs" | "sm" | "base" | "lg" | "xl" | "2xl" | "3xl";
};

const blockieSizeMap = {
  xs: 6,
  sm: 7,
  base: 8,
  lg: 9,
  xl: 10,
  "2xl": 12,
  "3xl": 15,
};

/**
 * Displays an address (or ENS) with a Blockie image and option to copy address.
 */
export const Address = ({
  address,
  disableAddressLink,
  format,
  size = "base",
}: AddressProps) => {
  const [ensAvatar, setEnsAvatar] = useState<string | null>();
  const [addressCopied, setAddressCopied] = useState(false);
  const [isUseBlockie, setIsUseBlockie] = useState(false);

  const { targetNetwork } = useTargetNetwork();
  const { data: fetchedProfile, isLoading } = useScaffoldStarkProfile(address);

  const checkSumAddress = useMemo(() => {
    if (!address) return undefined;
    return getChecksumAddress(address);
  }, [address]);

  const blockExplorerAddressLink = getBlockExplorerAddressLink(
    targetNetwork,
    checkSumAddress || address || "",
  );

  const [displayAddress, setDisplayAddress] = useState(
    checkSumAddress?.slice(0, 6) + "..." + checkSumAddress?.slice(-4),
  );

  useEffect(() => {
    const addressWithFallback = checkSumAddress || address || "";

    if (fetchedProfile?.name) {
      setDisplayAddress(fetchedProfile.name);
    } else if (format === "long") {
      setDisplayAddress(addressWithFallback || "");
    } else {
      setDisplayAddress(
        addressWithFallback.slice(0, 6) + "..." + addressWithFallback.slice(-4),
      );
    }
  }, [fetchedProfile, checkSumAddress, address, format]);

  // Skeleton UI
  if (!checkSumAddress || isLoading) {
    return (
      <div className="animate-pulse flex space-x-4">
        <div className="rounded-md bg-slate-300 h-6 w-6"></div>
        <div className="flex items-center space-y-6">
          <div className="h-2 w-28 bg-slate-300 rounded"></div>
        </div>
      </div>
    );
  }

  if (!validateChecksumAddress(checkSumAddress)) {
    return <span className="text-error">Wrong address</span>;
  }

  const TypedCopyToClipboard = CopyToClipboard as unknown as React.FC<{
    text: string;
    onCopy?: (text: string, result: boolean) => void;
    children?: React.ReactNode;
  }>;

  return (
    <div className="flex items-center">
      <div className="flex-shrink-0">
        {isUseBlockie ? (
          <BlockieAvatar
            address={checkSumAddress}
            ensImage={ensAvatar}
            size={(blockieSizeMap[size] * 24) / blockieSizeMap["base"]}
          />
        ) : (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={fetchedProfile?.profilePicture || ""}
            alt="Profile Picture"
            className="rounded-full h-6 w-6"
            width={24}
            height={24}
            onError={() => {
              setIsUseBlockie(true);
            }}
          />
        )}
      </div>
      {disableAddressLink ? (
        <span className={`ml-1.5 text-${size} font-normal`}>
          {fetchedProfile?.name || displayAddress}
        </span>
      ) : targetNetwork.network === devnet.network ? (
        <span className={`ml-1.5 text-${size} font-normal`}>
          <Link href={blockExplorerAddressLink}>
            {fetchedProfile?.name || displayAddress}
          </Link>
        </span>
      ) : (
        <a
          className={`ml-1.5 text-${size} font-normal`}
          target="_blank"
          href={blockExplorerAddressLink}
          rel="noopener noreferrer"
        >
          {fetchedProfile?.name || displayAddress}
        </a>
      )}
      {addressCopied ? (
        <CheckCircleIcon
          className="ml-1.5 text-xl font-normal text-sky-600 h-5 w-5 cursor-pointer"
          aria-hidden="true"
        />
      ) : (
        <TypedCopyToClipboard
          text={checkSumAddress}
          onCopy={() => {
            setAddressCopied(true);
            setTimeout(() => {
              setAddressCopied(false);
            }, 800);
          }}
        >
          <DocumentDuplicateIcon
            className="ml-1.5 text-xl font-normal text-sky-600 h-5 w-5 cursor-pointer"
            aria-hidden="true"
          />
        </TypedCopyToClipboard>
      )}
    </div>
  );
};
