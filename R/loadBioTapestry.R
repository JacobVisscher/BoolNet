
# Find a child node named <name>
# of <node>, or return NULL if such a node
# does not exist 
xmlFindNode <- function(node,name)
{
    indices <- which(xmlSApply(node, xmlName) ==  name)
    if (length(indices) == 0)
        return(NULL)
    return(xmlChildren(node)[indices])
}

# Parse all nodes in <rootNode> 
# (i.e., all nodes of a certain type),
# and write them to a list
parseGeneAttrs <- function(rootNode)
{
    i <- 0
    res <- xmlApply(rootNode,function(child)
        {
            i <<- i + 1
            attrs <- xmlAttrs(child)
            
            name <- unname(attrs["name"])
            if (name == "" | is.na(name))
              name <- paste(xmlName(child),i,sep="_")
            
            # find the "simulationLogic" node, which contains
            # the necessary logic information
            logic <- xmlFindNode(child,"simulationLogic")[[1]]
            
            initVal <- NULL
            if (is.null(logic))
            {
                warning(paste("Gene ",name," does not specify a simulation logic, assuming AND!",sep=""))
                logic <- "AND"
            }
            else
            {
              # try to find initial values in the simulation parameters
              params <- xmlFindNode(logic,"simParameters")
              if (!is.null(params))
              {
                for (param in xmlChildren(params[[1]]))
                {
                  pa <- xmlAttrs(param)
                  if (pa["name"] == "initVal")
                  {
                    initVal <- as.numeric(pa["value"])
                    if (initVal != 0 & initVal != 1)
                    # only 0 and 1 are allowed for the initialization
                    {
                       warning("Initial value for gene ",name," is neither 0 nor 1 and is ignored!",sep="")
                       initVal <- NULL
                    }
                    break
                  }
                }
              }
              
              # get the Boolean function of the node
              logic <- unname(xmlAttrs(logic)["type"])
            }
            
            list(id=unname(attrs["id"]),name=name,logic=logic,initVal=initVal,inputs=NULL)
        })     
}

# Parse all types of nodes (genes, signals, etc)
parseAllGenes <- function(rootNode)
{
  genes <- unlist(xmlApply(rootNode,parseGeneAttrs),recursive=FALSE)
  names(genes) <- lapply(genes,function(gene)gene$id)
  return(genes)
}

# Parse the links in the children of <node> and insert them
# into the input lists of the genes
parseAllLinks <- function(rootNode,geneList)
{
  for (link in xmlChildren(rootNode))
  {
      attrs <- xmlAttrs(link)
      
      if (is.na(attrs["sign"]))
      # a link with unspecified direction (inhibition or activation) was found
      {
        warning(paste("The link between \"",geneList[[attrs["src"]]]$name,
                      "\" and \"",geneList[[attrs["targ"]]]$name,
                      "\" is not specified as an enhancer or suppressor and is therefore ignored!",sep=""))
        
      }
      else
      {
        geneList[[attrs["targ"]]]$input[[length(geneList[[attrs["targ"]]]$input) + 1]] <- 
            list(input=unname(attrs["src"]),sign=attrs["sign"])
      }    
  }
  return(geneList)
}

# Load a BioTapestry file (*.btp) from <file>
# and convert it to a Boolean network
loadBioTapestry <- function(file)
{
    if (!require(XML))
        stop("Please install the XML package before using this function!")  
    
    doc <- xmlRoot(xmlTreeParse(file))
    
    # detect the "genome" XML node which holds the nodes and links of the network
    genome <- xmlFindNode(doc,"genome")[[1]]
    
    # find the "nodes" node that contains all genes/inputs/etc
    nodes <- xmlFindNode(genome,"nodes")[[1]]
    
    # read in genes
    geneList <- parseAllGenes(nodes)
    
    # find the "links" node that contains the links/dependencies
    links <- xmlFindNode(genome,"links")[[1]]
    
    # add links to gene list
    geneList <- parseAllLinks(links,geneList)
    
    # build up network structure
    genes <- unname(sapply(geneList,function(gene)gene$name))
    
    geneIds <- names(geneList)
    
    fixed <- rep(-1,length(genes))
    
    i <- 0
    interactions <- lapply(geneList,function(gene)
        {
            i <<- i + 1
            input <- sapply(gene$input,function(inp)
            {
                which(geneIds == inp$input) 
            })
            
            if (length(input) == 0)
            {
                if (!is.null(gene$initVal))
                # input-only gene without fixed value (=> depending on itself)
                {
                    input <- 0
                    func <- gene$initVal
                    fixed[i] <<- func
                    expr <- func
                } 
                else
                # input-only gene with fixed value
                {
                    input <- i
                    func <- c(0,1)
                    expr <- gene$name
                }
            }    
            else
            # dependent gene
            {
                # determine signs/negations of genes
                inputSigns <- sapply(gene$input,function(inp)inp$sign)  
        
                tt <- as.matrix(allcombn(2,length(input)) - 1)
                            
                func <- as.integer(switch(gene$logic,
                    AND = {
                            # calculate truth table for AND
                            apply(tt,1,function(assignment)
                            {
                                res <- 1
                                for (i in 1:length(assignment))
                                {
                                    if (inputSigns[i] == "+")
                                    res <- res & assignment[i]
                                    else
                                    res <- res & !assignment[i]
                                    if (!res)
                                    break
                                }
                                res
                            })
                        },
                    OR = {
                            # calculate truth table for OR
                            apply(tt,1,function(assignment)
                            {
                                res <- 0
                                for (i in 1:length(assignment))
                                {
                                    if (inputSigns[i] == "+")
                                    res <- res | assignment[i]
                                    else
                                    res <- res | !assignment[i]
                                    if (res)
                                    break
                                }
                                res
                            })
                        },
                    XOR = {
                            # calculate truth table for XOR
                            apply(tt,1,function(assignment)
                            {
                                res <- assignment[1]
                                for (i in 2:length(assignment))
                                {
                                    res <- xor(res,assignment[i])
                                }
                                res
                            })
                        },
                    stop(paste("Unknown Boolean operator \"",gene$logic,"\"!",sep=""))                            
                ))
                
                # get string representation of the input gene literals
                literals <- mapply(function(gene,sign)
                                    {
                                    if (sign == "+")
                                        gene
                                    else
                                        paste("!",gene,sep="")
                                    }, genes[input], inputSigns)
                
                # get string representation of function                    
                expr <- switch(gene$logic,
                    AND = {
                            paste(literals,collapse=" & ")
                        },
                    OR =  {
                            paste(literals,collapse=" | ")
                        },
                    XOR = {
                            getDNF(func,genes[input]) 
                          }      
                        )
            }
            return(list(input=input,func=func,expression=expr))
        })
        
    names(interactions) <- genes
    names(fixed) <- genes
        
    net <- list(genes=genes,interactions=interactions,fixed=fixed)
    class(net) <- "BooleanNetwork"
    return(net)
}